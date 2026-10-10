package main

// Data sources: the parts of a collection that a client offers as data sources of their own
// ("GTEx" and "TARGET" within TCGA-TARGET-GTEx), and, for each part, what makes sense inside
// it: the cohorts present, the presets that change its samples, the clinical columns that
// have a single value there. All of it is computed here, once, from the data, so that no
// client has to know anything about a dataset (dataset_registry.R mirrors this for the
// SQLite path of the R app; test_equivalence.R checks the two agree).
//
// A dataset declares its parts in dataset_meta:
//
//	source_col           a categorical clinical column (tcgatargetgtex: `study`)
//	sources              the levels offered as data sources, in order ("GTEX|TARGET")
//	source_labels        a display name per entry of `sources` (optional; the level itself)
//	source_descriptions  one line per entry (optional)
//
// The first source is always the whole collection (no rules). A level that is not one of
// the column's is logged and skipped. A dataset without `source_col` has the one source.

import (
	"fmt"
	"os"
)

type Source struct {
	Label       string       `json:"label"`
	Description string       `json:"description"`
	Rules       []PresetRule `json:"rules"`
	NSamples    int          `json:"n_samples"`
	Cohorts     []string     `json:"cohorts"`              // cohort values present, in `cohorts` table order
	Groups      []string     `json:"groups"`               // presets offered as alternatives within this source
	Exclusions  []string     `json:"exclusions"`           // presets offered as exclusions within this source
	SingleLevel []string     `json:"single_level_columns"` // categorical clinical columns with at most one value here
}

// rulesMask: which rows satisfy every rule (a rule holds when the row's value of the column
// is, or is not, one of the values; a missing value is never "in"). No rules = every row.
func (d *Dataset) rulesMask(rules []PresetRule) []bool {
	n := len(d.samples)
	m := make([]bool, n)
	for i := range m {
		m[i] = true
	}
	for _, r := range rules {
		col, ok := d.clinText[r.Column]
		if !ok {
			continue // validated before: cannot happen for a loaded preset
		}
		in := map[string]bool{}
		for _, v := range r.Values {
			in[v] = true
		}
		for i := range m {
			hit := col.ok[i] && in[col.val[i]]
			if r.Op == "in" {
				m[i] = m[i] && hit
			} else {
				m[i] = m[i] && !hit
			}
		}
	}
	return m
}

func countTrue(m []bool) int {
	n := 0
	for _, b := range m {
		if b {
			n++
		}
	}
	return n
}

// isExclusion: a preset that only removes samples (every rule a `not in`)
func isExclusion(p Preset) bool {
	if len(p.Rules) == 0 {
		return false
	}
	for _, r := range p.Rules {
		if r.Op != "not in" {
			return false
		}
	}
	return true
}

// narrows: does the preset keep some, but not all, of base?
func narrows(pm, base []bool) bool {
	inBase, kept := 0, 0
	for i := range base {
		if base[i] {
			inBase++
			if pm[i] {
				kept++
			}
		}
	}
	return kept > 0 && kept < inBase
}

// sameWithin: do the two masks agree on every row of base?
func sameWithin(a, b, base []bool) bool {
	for i := range base {
		if base[i] && a[i] != b[i] {
			return false
		}
	}
	return true
}

// loadSources computes the preset sample counts and the data sources. Runs after
// loadPresets (needs the presets) and before buildMeta (which publishes the result).
func (d *Dataset) loadSources() error {
	masks := map[string][]bool{}
	for i := range d.presets {
		m := d.rulesMask(d.presets[i].Rules)
		masks[d.presets[i].Label] = m
		d.presets[i].NSamples = countTrue(m)
	}
	// the cohort values in the order of the `cohorts` table (the R app's menu order)
	cohortOrder := []string{}
	if d.db == nil {
	} else if rows, err := d.db.Query("SELECT cohort FROM cohorts"); err == nil {
		for rows.Next() {
			var c string
			if rows.Scan(&c) == nil {
				cohortOrder = append(cohortOrder, c)
			}
		}
		rows.Close()
	}
	describe := func(label, desc string, rules []PresetRule) Source {
		base := d.rulesMask(rules)
		src := Source{Label: label, Description: desc, Rules: rules, NSamples: countTrue(base),
			Cohorts: []string{}, Groups: []string{}, Exclusions: []string{}, SingleLevel: []string{}}
		// cohorts present
		if col, ok := d.clinText["cohort"]; ok {
			present := map[string]bool{}
			for i := range base {
				if base[i] && col.ok[i] {
					present[col.val[i]] = true
				}
			}
			listed := map[string]bool{}
			for _, c := range cohortOrder {
				if present[c] && !listed[c] {
					src.Cohorts = append(src.Cohorts, c)
					listed[c] = true
				}
			}
			for _, c := range d.levels["cohort"] { // any present value the table does not list
				if present[c] && !listed[c] {
					src.Cohorts = append(src.Cohorts, c)
					listed[c] = true
				}
			}
		}
		// presets that change the samples of this source: exclusions, then the groups that
		// are not the same thing as an offered exclusion (the clearer control wins)
		var excl []Preset
		for _, p := range d.presets {
			if isExclusion(p) && narrows(masks[p.Label], base) {
				excl = append(excl, p)
				src.Exclusions = append(src.Exclusions, p.Label)
			}
		}
		for _, p := range d.presets {
			if isExclusion(p) || !narrows(masks[p.Label], base) {
				continue
			}
			dup := false
			for _, e := range excl {
				if sameWithin(masks[p.Label], masks[e.Label], base) {
					dup = true
				}
			}
			if !dup {
				src.Groups = append(src.Groups, p.Label)
			}
		}
		// categorical clinical columns with at most one value here
		for _, n := range d.clinOrder {
			col, ok := d.clinText[n]
			if !ok || len(d.levels[n]) == 0 {
				continue
			}
			seen := map[string]bool{}
			for i := range base {
				if base[i] && col.ok[i] {
					seen[col.val[i]] = true
				}
			}
			if len(seen) <= 1 {
				src.SingleLevel = append(src.SingleLevel, n)
			}
		}
		return src
	}
	d.sources = []Source{describe(d.Label, "", []PresetRule{})}
	if d.sourceCol == "" {
		return nil
	}
	if len(d.levels[d.sourceCol]) == 0 {
		fmt.Fprintf(os.Stderr, "dataset %s: source_col %q is not a categorical clinical column; no parts offered\n", d.Name, d.sourceCol)
		return nil
	}
	for i, lv := range d.sourceLevels {
		if !contains(d.levels[d.sourceCol], lv) {
			fmt.Fprintf(os.Stderr, "dataset %s: source %q is not a value of %s; skipped\n", d.Name, lv, d.sourceCol)
			continue
		}
		label, desc := lv, ""
		if i < len(d.sourceLabels) && d.sourceLabels[i] != "" {
			label = d.sourceLabels[i]
		}
		if i < len(d.sourceDescs) {
			desc = d.sourceDescs[i]
		}
		d.sources = append(d.sources, describe(label, desc, []PresetRule{{Column: d.sourceCol, Op: "in", Values: []string{lv}}}))
	}
	return nil
}
