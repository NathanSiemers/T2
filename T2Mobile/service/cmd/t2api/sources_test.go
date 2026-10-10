package main

import (
	"reflect"
	"testing"
)

// a small collection: two studies, cohorts, a sample type; built without a database
func sourcesFixture() *Dataset {
	col := func(vals ...string) textCol {
		c := textCol{val: vals, ok: make([]bool, len(vals))}
		for i, v := range vals {
			c.ok[i] = v != ""
		}
		return c
	}
	d := &Dataset{Name: "toy", Label: "Toy collection"}
	d.samples = []string{"s1", "s2", "s3", "s4", "s5", "s6"}
	d.clinOrder = []string{"study", "cohort", "sample_type", "note"}
	d.clinText = map[string]textCol{
		"study":       col("GTEX", "GTEX", "GTEX", "TARGET", "TARGET", "TCGA"),
		"cohort":      col("Liver", "Liver", "Blood", "AML", "Wilms", "LUAD"),
		"sample_type": col("Normal Tissue", "Normal Tissue", "Cell Line", "Primary Tumor", "Primary Tumor", "Primary Tumor"),
		"note":        col("x", "x", "x", "x", "", "x"),
	}
	d.levels = map[string][]string{
		"study": {"GTEX", "TARGET", "TCGA"}, "cohort": {"AML", "Blood", "Liver", "LUAD", "Wilms"},
		"sample_type": {"Cell Line", "Normal Tissue", "Primary Tumor"}, "note": {"x"},
	}
	d.presets = []Preset{
		{Label: "GTEx normal tissues", Rules: []PresetRule{{Column: "study", Op: "in", Values: []string{"GTEX"}}, {Column: "sample_type", Op: "in", Values: []string{"Normal Tissue"}}}},
		{Label: "TARGET pediatric cancers", Rules: []PresetRule{{Column: "study", Op: "in", Values: []string{"TARGET"}}}},
		{Label: "Exclude cell lines", Rules: []PresetRule{{Column: "sample_type", Op: "not in", Values: []string{"Cell Line"}}}},
		{Label: "Exclude tumors of heme origin", Rules: []PresetRule{{Column: "cohort", Op: "not in", Values: []string{"AML", "Blood"}}}},
	}
	d.sourceCol, d.sourceLevels, d.sourceLabels, d.sourceDescs = "study", []string{"GTEX", "TARGET", "NOPE"}, []string{"GTEx"}, []string{"The GTEx study"}
	return d
}

func TestRulesMask(t *testing.T) {
	d := sourcesFixture()
	got := d.rulesMask([]PresetRule{{Column: "study", Op: "in", Values: []string{"GTEX"}}, {Column: "sample_type", Op: "not in", Values: []string{"Cell Line"}}})
	if want := []bool{true, true, false, false, false, false}; !reflect.DeepEqual(got, want) {
		t.Errorf("mask: got %v want %v", got, want)
	}
	// a missing value is never "in", so `not in` keeps it
	got = d.rulesMask([]PresetRule{{Column: "note", Op: "not in", Values: []string{"x"}}})
	if want := []bool{false, false, false, false, true, false}; !reflect.DeepEqual(got, want) {
		t.Errorf("missing value under not-in: got %v want %v", got, want)
	}
	if n := countTrue(d.rulesMask(nil)); n != 6 {
		t.Errorf("no rules should keep every row, kept %d", n)
	}
}

func TestLoadSources(t *testing.T) {
	d := sourcesFixture()
	if err := d.loadSources(); err != nil {
		t.Fatal(err)
	}
	// preset counts over the whole collection
	counts := map[string]int{}
	for _, p := range d.presets {
		counts[p.Label] = p.NSamples
	}
	if !reflect.DeepEqual(counts, map[string]int{"GTEx normal tissues": 2, "TARGET pediatric cancers": 2, "Exclude cell lines": 5, "Exclude tumors of heme origin": 4}) {
		t.Errorf("preset counts: %v", counts)
	}
	// the whole collection, GTEx, TARGET; the unknown level skipped
	if len(d.sources) != 3 {
		t.Fatalf("expected 3 sources, got %+v", d.sources)
	}
	all, gtex, target := d.sources[0], d.sources[1], d.sources[2]
	if all.Label != "Toy collection" || all.NSamples != 6 || len(all.Rules) != 0 {
		t.Errorf("whole collection: %+v", all)
	}
	if !reflect.DeepEqual(all.Groups, []string{"GTEx normal tissues", "TARGET pediatric cancers"}) ||
		!reflect.DeepEqual(all.Exclusions, []string{"Exclude cell lines", "Exclude tumors of heme origin"}) {
		t.Errorf("whole collection offers: groups %v exclusions %v", all.Groups, all.Exclusions)
	}
	if !reflect.DeepEqual(all.SingleLevel, []string{"note"}) {
		t.Errorf("whole collection single-level columns: %v", all.SingleLevel)
	}
	// GTEx: label and description from the meta; study has one level here; "GTEx normal
	// tissues" is the same as "Exclude cell lines" within GTEx, so only the exclusion is offered
	if gtex.Label != "GTEx" || gtex.Description != "The GTEx study" || gtex.NSamples != 3 {
		t.Errorf("GTEx: %+v", gtex)
	}
	if !reflect.DeepEqual(gtex.Rules, []PresetRule{{Column: "study", Op: "in", Values: []string{"GTEX"}}}) {
		t.Errorf("GTEx rules: %+v", gtex.Rules)
	}
	if len(gtex.Groups) != 0 || !reflect.DeepEqual(gtex.Exclusions, []string{"Exclude cell lines", "Exclude tumors of heme origin"}) {
		t.Errorf("GTEx offers: groups %v exclusions %v", gtex.Groups, gtex.Exclusions)
	}
	if !reflect.DeepEqual(gtex.SingleLevel, []string{"study", "note"}) {
		t.Errorf("GTEx single-level columns: %v", gtex.SingleLevel)
	}
	if !reflect.DeepEqual(gtex.Cohorts, []string{"Blood", "Liver"}) { // no cohorts table: level order
		t.Errorf("GTEx cohorts: %v", gtex.Cohorts)
	}
	// TARGET: the label falls back to the level; its own preset does not narrow it; the heme
	// exclusion does (AML), cell lines do not
	if target.Label != "TARGET" || target.Description != "" || target.NSamples != 2 {
		t.Errorf("TARGET: %+v", target)
	}
	if len(target.Groups) != 0 || !reflect.DeepEqual(target.Exclusions, []string{"Exclude tumors of heme origin"}) {
		t.Errorf("TARGET offers: groups %v exclusions %v", target.Groups, target.Exclusions)
	}
	if !reflect.DeepEqual(target.SingleLevel, []string{"study", "sample_type", "note"}) { // note: one value, one missing
		t.Errorf("TARGET single-level columns: %v", target.SingleLevel)
	}
}

func TestLoadSourcesWithoutParts(t *testing.T) {
	d := sourcesFixture()
	d.sourceCol = ""
	if err := d.loadSources(); err != nil {
		t.Fatal(err)
	}
	if len(d.sources) != 1 || d.sources[0].NSamples != 6 {
		t.Errorf("a dataset without parts has the one source: %+v", d.sources)
	}
	d = sourcesFixture()
	d.sourceCol = "nosuch"
	if err := d.loadSources(); err != nil || len(d.sources) != 1 {
		t.Errorf("an unknown source column gives the one source: %v %+v", err, d.sources)
	}
}
