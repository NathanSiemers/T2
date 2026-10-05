package main

// One T2 dataset: what is loaded once at start (samples, the clinical table, which samples
// were tested for which data type, the probe name list) and how one probe's values are
// fetched. The rules here are gitr()'s (gitr.R in the T2 repository), restated:
//
//   - The sample universe and order are the rows of `clinpheno`.
//   - A NUMERIC probe has a data type (probe_types). For a sample tested for that type the
//     value is the stored one, a stored NULL is missing, and NO stored row means the type's
//     default (0) if the type was loaded sparsely, missing if it was loaded in full (table
//     `sparse`). A sample not tested for the type is missing.        [view `tcgas`]
//   - Otherwise the probe is CATEGORICAL: the stored text value, missing where there is no
//     row.                                                           [view `tcgacats`]
//   - A numeric probe whose data type is declared "factor" in `datatypes` (mutations, copy
//     number calls ...) is reported as categorical, its numbers as level names ("0", "1").
//   - Clinical columns come straight from `clinpheno`: text is categorical, numbers numeric.
//     Virtual columns `subtype` and `cohort` are copies of the dataset's role columns (the
//     table's own `cohort`, if any, becomes `lcohort`). The sample-type column uses the
//     dataset's declared level order; a value outside it is missing.

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	_ "modernc.org/sqlite"
)

type Roles struct {
	CohortCol        string   `json:"cohort_col"`
	SubtypeCol       string   `json:"subtype_col"`
	SampletypeCol    string   `json:"sampletype_col"`
	NormalLabel      []string `json:"normal_label"`
	HemeValues       []string `json:"heme_values"`
	SampletypeLevels []string `json:"sampletype_levels"`
}

type Dataset struct {
	Name, Path, Title, Label string
	Roles                    Roles
	Defaults                 map[string]string

	db      *sql.DB
	version string // changes when the database file does; part of every ETag

	samples   []string         // sample ids, clinpheno order: THE row order of every column
	keyToRow  map[int64]int32  // samples.key -> row
	tested    map[string][]bool // data type -> row tested?
	sparse    map[string]sparseType // data type -> how it was loaded (table `sparse`); absent = sparse, default 0
	dtype     map[string]string // data type -> "numeric" | "factor"
	clin      map[string][]byte // encoded clinical + virtual columns
	clinOrder []string

	probeNames []string // selectable names (allprobes), for search
	probeLower []string

	levels  map[string][]string // categorical clinical/virtual column -> its levels
	presets []Preset

	clinicalJSON []byte
	metaJSON     []byte
	cache        *columnCache
}

// the canonical TCGA database predates dataset_meta; its roles are fixed (dataset_registry.R)
var tcgaRoles = Roles{
	CohortCol: "tumtype", SubtypeCol: "Subtype_Selected", SampletypeCol: "sample_type",
	NormalLabel: []string{"Solid Tissue Normal"}, HemeValues: []string{"LAML", "THYM", "DLBC"},
	SampletypeLevels: []string{"Primary Tumor", "Recurrent Tumor", "Metastatic", "Additional - New Primary",
		"Additional Metastatic", "Primary Blood Derived Cancer - Peripheral Blood", "Solid Tissue Normal"},
}

// database connections per dataset (set from -db-conns)
var dbConns = 48

func openDataset(name, path string, cacheBytes int64) (*Dataset, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	// read-only + immutable: no locks, no journal, no writes of any kind
	// A small page cache per connection (4 MB): the operating system's file cache is shared
	// by all connections and by the other T2 containers, a private one is not. Many
	// connections, because an uncached probe is ~11,000 scattered row reads and an SSD
	// array serves those in parallel.
	dsn := "file:" + path + "?mode=ro&immutable=1&_pragma=query_only(1)&_pragma=cache_size(-4096)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(dbConns)
	db.SetMaxIdleConns(dbConns)
	d := &Dataset{Name: name, Path: path, db: db,
		version: fmt.Sprintf("%x%x", fi.Size(), fi.ModTime().Unix()),
		cache:   newColumnCache(cacheBytes)}
	steps := []func() error{d.loadRoles, d.loadClinical, d.loadSamples, d.loadTested, d.loadSparse, d.loadDatatypes, d.loadProbeNames, d.loadPresets, d.buildMeta}
	for _, f := range steps {
		if err := f(); err != nil {
			db.Close()
			return nil, err
		}
	}
	return d, nil
}

// cleanText makes database text safe for JSON, which must be valid UTF-8: every byte that
// is not valid UTF-8 becomes one ordinary space. (tcgatargetgtex has a stray 0xCA, a Mac
// non-breaking space, in "Sympathetic Nervous System".) This is the ONE place where the API
// does not return the database's bytes exactly; test_equivalence.R reports what it affects.
func cleanText(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			b.WriteByte(' ')
		} else {
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	return b.String()
}

func splitMeta(s string) []string {
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// loadRoles mirrors .resolve_roles(): TCGA constants, else dataset_meta, else introspection
// (the introspection step needs the clinical columns and is finished in loadClinical).
func (d *Dataset) loadRoles() error {
	d.Defaults = map[string]string{"x": "cohort", "y": "", "color": "", "size": "", "condition": ""}
	d.Title, d.Label = d.Name, d.Name
	if d.Name == "TCGA" {
		d.Roles = tcgaRoles
		d.Title, d.Label = "T2: TCGA 2018 Pan-Cancer Database", "TCGA Pan-Cancer 2018"
		d.Defaults = map[string]string{"x": "cohort", "y": "CD8A", "color": "sample_type", "size": "", "condition": "StromalScore.estimate"}
		return nil
	}
	rows, err := d.db.Query("SELECT key, value FROM dataset_meta")
	if err != nil {
		d.Roles = Roles{CohortCol: "?"} // "?" = decide from the clinical column names
		return nil
	}
	defer rows.Close()
	m := map[string]string{}
	for rows.Next() {
		var k string
		var v sql.NullString
		if err := rows.Scan(&k, &v); err != nil {
			return err
		}
		m[k] = v.String
	}
	d.Roles = Roles{CohortCol: m["cohort_col"], SubtypeCol: m["subtype_col"], SampletypeCol: m["sampletype_col"],
		NormalLabel: splitMeta(m["normal_label"]), HemeValues: splitMeta(m["heme_values"]),
		SampletypeLevels: splitMeta(m["sampletype_levels"])}
	if m["title"] != "" {
		d.Title, d.Label = m["title"], m["title"]
	}
	if m["label"] != "" {
		d.Label = m["label"]
	}
	for _, k := range []string{"x", "y", "color", "size", "condition"} {
		if v := m["default_"+k]; v != "" {
			d.Defaults[k] = v
		}
	}
	return rows.Err()
}

func pick(have map[string]bool, cands ...string) string {
	for _, c := range cands {
		if have[c] {
			return c
		}
	}
	return ""
}

// loadClinical reads the whole clinpheno table (it is small: one row per sample), fixes the
// sample order, and encodes every clinical and virtual column once.
func (d *Dataset) loadClinical() error {
	rows, err := d.db.Query("SELECT * FROM clinpheno")
	if err != nil {
		return err
	}
	defer rows.Close()
	names, err := rows.Columns()
	if err != nil {
		return err
	}
	cols := make([][]any, len(names))
	for rows.Next() {
		vals := make([]any, len(names))
		ptrs := make([]any, len(names))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			if str, ok := v.(string); ok {
				v = cleanText(str)
			}
			cols[i] = append(cols[i], v)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	byName := map[string][]any{}
	have := map[string]bool{}
	for i, n := range names {
		byName[n] = cols[i]
		have[n] = true
	}
	sc, ok := byName["sample"]
	if !ok {
		return fmt.Errorf("clinpheno has no `sample` column")
	}
	d.samples = make([]string, len(sc))
	for i, v := range sc {
		d.samples[i] = fmt.Sprint(v)
	}
	if d.Roles.CohortCol == "?" { // no dataset_meta: introspect, as the R code does
		d.Roles = Roles{CohortCol: pick(have, "tumtype", "cohort", "group", "dataset"),
			SubtypeCol: pick(have, "Subtype_Selected", "subtype"), SampletypeCol: pick(have, "sample_type", "sampletype"),
			NormalLabel: []string{}, HemeValues: []string{}, SampletypeLevels: []string{}}
	}
	// virtual columns, exactly as gitr adds them
	order := []string{}
	for _, n := range names {
		if n != "sample" {
			order = append(order, n)
		}
	}
	if c := d.Roles.SubtypeCol; c != "" && have[c] {
		if !have["subtype"] {
			order = append(order, "subtype")
		}
		byName["subtype"] = byName[c]
	}
	if c := d.Roles.CohortCol; c != "" && have[c] {
		if have["cohort"] {
			byName["lcohort"] = byName["cohort"]
			order = append(order, "lcohort")
		} else {
			order = append(order, "cohort")
		}
		byName["cohort"] = byName[c]
	}
	d.clin = map[string][]byte{}
	d.levels = map[string][]string{}
	d.clinOrder = order
	for _, n := range order {
		typ := "clinical"
		if n == "cohort" || n == "subtype" || n == "lcohort" {
			typ = "virtual"
		}
		var levels []string
		if n == d.Roles.SampletypeCol && len(d.Roles.SampletypeLevels) > 0 {
			levels = d.Roles.SampletypeLevels
		}
		d.clin[n] = encodeAny(n, typ, byName[n], levels)
		d.levels[n] = levelsOf(byName[n], levels)
	}
	// the /clinical response: samples + every clinical column
	sj, _ := json.Marshal(d.samples)
	buf := []byte(fmt.Sprintf(`{"dataset":%s,"n":%d,"samples":%s,"columns":[`, jsonString(d.Name), len(d.samples), sj))
	for i, n := range order {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = append(buf, d.clin[n]...)
	}
	d.clinicalJSON = append(buf, ']', '}')
	return nil
}

func (d *Dataset) loadSamples() error {
	row := map[string]int32{}
	for i, s := range d.samples {
		row[s] = int32(i)
	}
	rows, err := d.db.Query("SELECT key, sample FROM samples")
	if err != nil {
		return err
	}
	defer rows.Close()
	d.keyToRow = map[int64]int32{}
	for rows.Next() {
		var k int64
		var s string
		if err := rows.Scan(&k, &s); err != nil {
			return err
		}
		if r, ok := row[s]; ok {
			d.keyToRow[k] = r
		}
	}
	return rows.Err()
}

func (d *Dataset) loadTested() error {
	row := map[string]int32{}
	for i, s := range d.samples {
		row[s] = int32(i)
	}
	// the view joins tested to samples by name: a tested sample with no `samples` row is not in it
	rows, err := d.db.Query("SELECT t.type, t.sample FROM tested t JOIN samples sa ON sa.sample = t.sample")
	if err != nil {
		return err
	}
	defer rows.Close()
	d.tested = map[string][]bool{}
	for rows.Next() {
		var typ, s string
		if err := rows.Scan(&typ, &s); err != nil {
			return err
		}
		r, ok := row[s]
		if !ok {
			continue
		}
		if d.tested[typ] == nil {
			d.tested[typ] = make([]bool, len(d.samples))
		}
		d.tested[typ][r] = true
	}
	return rows.Err()
}

// sparseType says what a missing row means for a sample tested for the type: for a type
// loaded sparsely (zeros not stored) the default value, for a type loaded in full: missing.
type sparseType struct {
	sparse bool
	def    float64
}

// loadSparse reads the `sparse` table (written by the database build since October 2026).
// Databases without it behave as before: every type sparse with default 0, exactly as the
// view `tcgas` treats a type that has no row in the table.
func (d *Dataset) loadSparse() error {
	d.sparse = map[string]sparseType{}
	rows, err := d.db.Query("SELECT type, sparse, default_value FROM sparse")
	if err != nil {
		return nil // optional table
	}
	defer rows.Close()
	for rows.Next() {
		var typ string
		var sp sql.NullInt64
		var def sql.NullFloat64
		if err := rows.Scan(&typ, &sp, &def); err != nil {
			return err
		}
		st := sparseType{sparse: !sp.Valid || sp.Int64 == 1}
		if def.Valid {
			st.def = def.Float64
		}
		d.sparse[typ] = st
	}
	return rows.Err()
}

func (d *Dataset) loadDatatypes() error {
	d.dtype = map[string]string{}
	rows, err := d.db.Query("SELECT type, r_datatype FROM datatypes")
	if err != nil {
		return nil // optional table
	}
	defer rows.Close()
	for rows.Next() {
		var t string
		var r sql.NullString
		if err := rows.Scan(&t, &r); err != nil {
			return err
		}
		d.dtype[t] = r.String
	}
	return rows.Err()
}

// loadProbeNames builds the searchable list in the order the T2 selectors use:
// subtype, cohort, every name in allprobes, then the sample-type column.
func (d *Dataset) loadProbeNames() error {
	rows, err := d.db.Query("SELECT probe FROM allprobes")
	if err != nil {
		return err
	}
	defer rows.Close()
	seen := map[string]bool{}
	add := func(n string) {
		if n != "" && n != "sample" && !seen[n] {
			seen[n] = true
			d.probeNames = append(d.probeNames, n)
			d.probeLower = append(d.probeLower, strings.ToLower(n))
		}
	}
	for _, v := range []string{"subtype", "cohort"} {
		if _, ok := d.clin[v]; ok {
			add(v)
		}
	}
	for rows.Next() {
		var p sql.NullString
		if err := rows.Scan(&p); err != nil {
			return err
		}
		add(p.String)
	}
	if _, ok := d.clin[d.Roles.SampletypeCol]; ok {
		add(d.Roles.SampletypeCol)
	}
	// clinical columns that are not in allprobes are still valid (survival times, ...)
	for _, n := range d.clinOrder {
		add(n)
	}
	return rows.Err()
}

// the distinct text values of a raw column (nil for a numeric column)
func levelsOf(vals []any, fixed []string) []string {
	if fixed != nil {
		return fixed
	}
	seen := map[string]bool{}
	out := []string{}
	for _, v := range vals {
		if s, ok := v.(string); ok && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// A preset is a named subset of samples the app offers as a one-tap choice ("GTEx normal
// tissues"). It is a list of rules over categorical clinical columns: the values of one rule
// are alternatives, and all rules of a preset must hold.
type PresetRule struct {
	Column string   `json:"column"`
	Op     string   `json:"op"` // "in" | "not in"
	Values []string `json:"values"`
}
type Preset struct {
	Label       string       `json:"label"`
	Description string       `json:"description"`
	Default     bool         `json:"default"` // switched on when the dataset is first opened
	Source      string       `json:"source"`  // "database" (table default_filters) | "derived" (from the role map)
	Rules       []PresetRule `json:"rules"`
}

// loadPresets reads the dataset's own `default_filters` table:
//
//	default_filters(preset, description, column_name, op, value, on_by_default, sort_order)
//
// one row per (preset, column, value). Rows naming a column or a value the dataset does not
// have are dropped (and logged), so a typo cannot produce a filter that silently selects
// nothing. A database without the table gets presets derived from its role map, so the app
// always has the two classic T2 choices (exclude non-tumor, exclude heme).
func (d *Dataset) loadPresets() error {
	d.presets = []Preset{}
	rows, err := d.db.Query(`SELECT preset, description, column_name, op, value, on_by_default
	                         FROM default_filters ORDER BY sort_order, rowid`)
	if err != nil {
		d.derivePresets()
		return nil
	}
	defer rows.Close()
	byLabel := map[string]int{}
	for rows.Next() {
		var label, col, op, val string
		var desc sql.NullString
		var on sql.NullInt64
		if err := rows.Scan(&label, &desc, &col, &op, &val, &on); err != nil {
			return err
		}
		op = strings.ToLower(strings.TrimSpace(op))
		lv, known := d.levels[col]
		if !known || (op != "in" && op != "not in") || !contains(lv, val) {
			fmt.Fprintf(os.Stderr, "dataset %s: default_filters row ignored (preset %q: %s %s %q)\n", d.Name, label, col, op, val)
			continue
		}
		i, ok := byLabel[label]
		if !ok {
			i = len(d.presets)
			byLabel[label] = i
			d.presets = append(d.presets, Preset{Label: label, Description: desc.String, Source: "database"})
		}
		p := &d.presets[i]
		p.Default = p.Default || on.Int64 != 0
		found := false
		for j := range p.Rules {
			if p.Rules[j].Column == col && p.Rules[j].Op == op {
				p.Rules[j].Values = append(p.Rules[j].Values, val)
				found = true
			}
		}
		if !found {
			p.Rules = append(p.Rules, PresetRule{Column: col, Op: op, Values: []string{val}})
		}
	}
	return rows.Err()
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func (d *Dataset) derivePresets() {
	keep := func(col string, vals []string) []string {
		out := []string{}
		for _, v := range vals {
			if contains(d.levels[col], v) {
				out = append(out, v)
			}
		}
		return out
	}
	if st := d.Roles.SampletypeCol; st != "" {
		if v := keep(st, d.Roles.NormalLabel); len(v) > 0 {
			d.presets = append(d.presets, Preset{Label: "Exclude non-tumor", Description: "Tumor samples only", Source: "derived",
				Rules: []PresetRule{{Column: st, Op: "not in", Values: v}}})
		}
	}
	if _, ok := d.levels["cohort"]; ok {
		if v := keep("cohort", d.Roles.HemeValues); len(v) > 0 {
			d.presets = append(d.presets, Preset{Label: "Exclude tumors of heme origin", Description: "Drop blood and lymphoid cohorts", Source: "derived",
				Rules: []PresetRule{{Column: "cohort", Op: "not in", Values: v}}})
		}
	}
}

// buildMeta: roles, defaults, cohort display names and the data-type descriptions.
func (d *Dataset) buildMeta() error {
	table := func(q string) []map[string]any {
		out := []map[string]any{}
		rows, err := d.db.Query(q)
		if err != nil {
			return out
		}
		defer rows.Close()
		names, _ := rows.Columns()
		for rows.Next() {
			vals := make([]any, len(names))
			ptrs := make([]any, len(names))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if rows.Scan(ptrs...) != nil {
				break
			}
			m := map[string]any{}
			for i, n := range names {
				if b, ok := vals[i].([]byte); ok {
					vals[i] = string(b)
				}
				m[n] = vals[i]
			}
			out = append(out, m)
		}
		return out
	}
	types := table("SELECT type, description, example, reference, source_file, source_url FROM types ORDER BY type")
	if len(types) == 0 {
		types = table("SELECT type FROM types ORDER BY type")
	}
	meta := map[string]any{
		"dataset": d.Name, "title": d.Title, "label": d.Label, "version": d.version,
		"n_samples": len(d.samples), "n_probes": len(d.probeNames),
		"roles": d.Roles, "defaults": d.Defaults,
		"presets": d.presets,
		"clinical_columns": d.clinOrder,
		"survival_endpoints": []string{"OS", "PFI", "DSS", "DFI"},
		"cohorts":            table("SELECT * FROM cohorts"),
		"types":              types,
		"datatypes":          d.dtype,
	}
	var err error
	d.metaJSON, err = json.Marshal(meta)
	return err
}

// ---------------------------------------------------------------------------------------
// one column

// column returns the encoded JSON object for one name, or nil if the dataset has no such
// variable. Probe columns are cached; concurrent requests for the same probe share one query.
func (d *Dataset) column(name string) ([]byte, error) {
	if c, ok := d.clin[name]; ok {
		return c, nil
	}
	return d.cache.get(name, func() ([]byte, error) { return d.fetchProbe(name) })
}

func (d *Dataset) fetchProbe(name string) ([]byte, error) {
	var key int64
	err := d.db.QueryRow("SELECT key FROM probes WHERE probe = ?", name).Scan(&key)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	n := len(d.samples)
	var typ sql.NullString
	err = d.db.QueryRow("SELECT type FROM probe_types WHERE probekey = ? ORDER BY rowid LIMIT 1", key).Scan(&typ)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	if err == nil { // numeric probe: dense over the samples tested for its type
		vals := make([]float64, n)
		tested := d.tested[typ.String]
		st, known := d.sparse[typ.String]
		if !known {
			st = sparseType{sparse: true}
		}
		for i := range vals {
			if tested == nil || !tested[i] || !st.sparse {
				vals[i] = math.NaN() // not tested, or the type is stored in full: missing unless a row says otherwise
			} else {
				vals[i] = st.def // tested, sparse type, no stored row: the default (0)
			}
		}
		rows, err := d.db.Query("SELECT samplekey, value FROM tcgai WHERE probekey = ? AND type = ?", key, typ.String)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var sk int64
			var v sql.NullFloat64
			if err := rows.Scan(&sk, &v); err != nil {
				return nil, err
			}
			r, ok := d.keyToRow[sk]
			if !ok || tested == nil || !tested[r] {
				continue
			}
			if v.Valid {
				vals[r] = v.Float64
			} else {
				vals[r] = math.NaN() // stored NULL: genuinely missing
			}
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
		if d.declaredType(name, typ.String) == "factor" {
			return encodeNumAsCat(name, typ.String, vals), nil
		}
		return encodeNum(name, typ.String, vals), nil
	}
	// categorical probe
	rows, err := d.db.Query("SELECT samplekey, value, type FROM tcgacati WHERE probekey = ?", key)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	// A sample can have several values for one categorical probe (two mutations of one
	// gene in .fmut). Exactly as gitr() does, keep the smallest value in byte order: a rule
	// that does not depend on the order in which SQLite returns the rows (that order follows
	// whichever index is used).
	raw := make([]string, n)
	has := make([]bool, n)
	ctype, found := "", false
	for rows.Next() {
		var sk int64
		var v, t sql.NullString
		if err := rows.Scan(&sk, &v, &t); err != nil {
			return nil, err
		}
		found = true
		ctype = t.String
		if r, ok := d.keyToRow[sk]; ok && v.Valid && (!has[r] || v.String < raw[r]) {
			raw[r], has[r] = v.String, true
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}
	vals := make([]any, n)
	for r := range raw {
		if has[r] {
			vals[r] = cleanText(raw[r])
		}
	}
	return encodeAny(name, ctype, vals, nil), nil
}

// declaredType: the R class gitr gives a probe -- by the suffix after its last ".", else by
// its data type, else numeric.
func (d *Dataset) declaredType(name, typ string) string {
	if i := strings.LastIndex(name, "."); i >= 0 {
		if t, ok := d.dtype[name[i+1:]]; ok {
			return t
		}
	}
	if t, ok := d.dtype[typ]; ok {
		return t
	}
	return "numeric"
}

// ---------------------------------------------------------------------------------------
// encoding: {"name":..,"kind":"num","type":..,"values":[1.5,null,...]}
//           {"name":..,"kind":"cat","type":..,"levels":[..],"codes":[0,2,-1,...]}   (-1 = missing)

func header(name, kind, typ string) []byte {
	return []byte(fmt.Sprintf(`{"name":%s,"kind":"%s","type":%s,`, jsonString(name), kind, jsonString(typ)))
}

func encodeNum(name, typ string, vals []float64) []byte {
	b := append(header(name, "num", typ), `"values":[`...)
	for i, v := range vals {
		if i > 0 {
			b = append(b, ',')
		}
		if math.IsNaN(v) || math.IsInf(v, 0) {
			b = append(b, "null"...)
		} else {
			b = strconv.AppendFloat(b, v, 'g', -1, 64)
		}
	}
	return append(b, ']', '}')
}

func encodeCodes(name, typ string, levels []string, codes []int32) []byte {
	lj, _ := json.Marshal(levels)
	b := append(header(name, "cat", typ), `"levels":`...)
	b = append(b, lj...)
	b = append(b, `,"codes":[`...)
	for i, c := range codes {
		if i > 0 {
			b = append(b, ',')
		}
		b = strconv.AppendInt(b, int64(c), 10)
	}
	return append(b, ']', '}')
}

// a number as R's as.character() writes it (15 significant digits): 1 -> "1", 0.5 -> "0.5"
func rNumber(v float64) string { return strconv.FormatFloat(v, 'g', 15, 64) }

func encodeNumAsCat(name, typ string, vals []float64) []byte {
	uniq := map[float64]bool{}
	for _, v := range vals {
		if !math.IsNaN(v) {
			uniq[v] = true
		}
	}
	nums := make([]float64, 0, len(uniq))
	for v := range uniq {
		nums = append(nums, v)
	}
	sort.Float64s(nums)
	levels := make([]string, len(nums))
	idx := map[float64]int32{}
	for i, v := range nums {
		levels[i] = rNumber(v)
		idx[v] = int32(i)
	}
	codes := make([]int32, len(vals))
	for i, v := range vals {
		if math.IsNaN(v) {
			codes[i] = -1
		} else {
			codes[i] = idx[v]
		}
	}
	return encodeCodes(name, typ, levels, codes)
}

// encodeAny encodes a column read as raw database values: numeric if every present value is
// a number, else categorical. fixedLevels, if given, is the level order to use; values
// outside it are missing.
func encodeAny(name, typ string, vals []any, fixedLevels []string) []byte {
	numeric, present := fixedLevels == nil, false
	for _, v := range vals {
		switch v.(type) {
		case nil:
		case int64, float64:
			present = true
		default:
			present = true
			numeric = false
		}
	}
	if numeric && present {
		out := make([]float64, len(vals))
		for i, v := range vals {
			switch x := v.(type) {
			case int64:
				out[i] = float64(x)
			case float64:
				out[i] = x
			default:
				out[i] = math.NaN()
			}
		}
		return encodeNum(name, typ, out)
	}
	str := make([]string, len(vals))
	ok := make([]bool, len(vals))
	uniq := map[string]bool{}
	for i, v := range vals {
		switch x := v.(type) {
		case nil:
			continue
		case string:
			str[i] = x
		case float64:
			str[i] = rNumber(x)
		default:
			str[i] = fmt.Sprint(x)
		}
		ok[i] = true
		uniq[str[i]] = true
	}
	levels := fixedLevels
	if levels == nil {
		levels = make([]string, 0, len(uniq))
		for s := range uniq {
			levels = append(levels, s)
		}
		// alphabetical, ignoring case first (close to R's locale sort; order is cosmetic)
		sort.Slice(levels, func(i, j int) bool {
			a, b := strings.ToLower(levels[i]), strings.ToLower(levels[j])
			if a != b {
				return a < b
			}
			return levels[i] < levels[j]
		})
	}
	idx := map[string]int32{}
	for i, l := range levels {
		idx[l] = int32(i)
	}
	codes := make([]int32, len(vals))
	for i := range vals {
		codes[i] = -1
		if ok[i] {
			if c, found := idx[str[i]]; found {
				codes[i] = c
			}
		}
	}
	return encodeCodes(name, typ, levels, codes)
}
