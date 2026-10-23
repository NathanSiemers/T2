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
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
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
	Hidden                   bool // dataset_meta `hidden`: still served, but the apps do not list it
	Roles                    Roles
	Defaults                 map[string]string

	db      *sql.DB
	version string // changes when the database file does; part of every ETag

	samples   []string              // sample ids, clinpheno order: THE row order of every column
	keyToRow  map[int64]int32       // samples.key -> row
	tested    map[string][]bool     // data type -> row tested?
	sparse    map[string]sparseType // data type -> how it was loaded (table `sparse`); absent = sparse, default 0
	dtype     map[string]string     // data type -> "numeric" | "factor"
	clin      map[string][]byte     // encoded clinical + virtual columns
	clinOrder []string

	probeNames []string            // selectable names (allprobes), for search
	known      map[string]struct{} // every name that can have data: allprobes + probes + clinical
	fileSize   int64               // identity of the file the maps below were loaded from
	fileMtime  time.Time
	fileIno    uint64
	probeLower []string

	levels   map[string][]string // categorical clinical/virtual column -> its levels
	clinText map[string]textCol  // raw text per row of every clinical/virtual column (for preset rules)
	presets  []Preset
	sources  []Source
	// the dataset's parts (dataset_meta source_col / sources / source_labels / source_descriptions)
	sourceCol                               string
	sourceLevels, sourceLabels, sourceDescs []string

	probesJSON []byte

	meta       map[string]string // the raw dataset_meta table (nil-safe: empty when the file has none)
	handles    []Handle          // the columns that play cohort / sub-cohort / sample type
	clinNum    map[string]bool   // clinical + virtual column -> numeric?
	tte        []TTEVariable
	references []Reference
	typeLabels map[string]string
	fillOpts   map[string][]string // data type -> its fill options (types.fill_options); absent = na only
	cohortOnce sync.Once
	cohortIdx  []int32 // per sample row: index of its cohort level, -1 = no cohort
	nCohorts   int
	hasLabel   bool // types.label exists

	// the typed variable list, parallel to probeNames (small codes, built once at load)
	typedTypes   []string // type names used; codes below index into it
	typedSection []uint8  // 0 handle, 1 probe, 2 clinical
	typedType    []uint16
	typedKind    []uint8 // 0 num, 1 cat

	clinicalJSON []byte
	metaJSON     []byte
	cache        *columnCache
}

// Handle: a column that plays a dataset-wide role (see DATASET-CONTRACT.md).
type Handle struct {
	Name string `json:"name"`
	Role string `json:"role"` // cohort | subcohort | sample_type
}

// TTEVariable: a time-to-event variable, a pair of numeric clinical columns.
type TTEVariable struct {
	Name        string `json:"name"`
	Label       string `json:"label"`
	EventCol    string `json:"event_col"`
	TimeCol     string `json:"time_col"`
	TimeUnit    string `json:"time_unit"`
	Description string `json:"description"`
}

// database connections per dataset (set from -db-conns)
var dbConns = 48

func openDataset(name, path string, cache *columnCache) (*Dataset, error) {
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
	d := &Dataset{Name: name, Path: path, db: db, known: map[string]struct{}{},
		fileSize: fi.Size(), fileMtime: fi.ModTime(), fileIno: inode(fi),
		version: fileVersion(path, fi),
		cache:   cache}
	steps := []func() error{d.loadRoles, d.loadClinical, d.loadTTE, d.loadReferences, d.loadSamples, d.loadTested, d.loadSparse, d.loadDatatypes, d.loadProbeNames, d.loadPresets, d.loadSources, d.buildMeta}
	for _, f := range steps {
		if err := f(); err != nil {
			db.Close()
			return nil, err
		}
	}
	return d, nil
}

// fileVersion: size and mtime, plus the SQLite header's file change counter (bytes 24..27)
// when it can be read, so a rebuild of equal size within one second still differs.
func fileVersion(path string, fi os.FileInfo) string {
	v := fmt.Sprintf("%x%x", fi.Size(), fi.ModTime().Unix())
	f, err := os.Open(path)
	if err != nil {
		return v
	}
	defer f.Close()
	var h [4]byte
	if _, err := f.ReadAt(h[:], 24); err != nil {
		return v
	}
	return v + fmt.Sprintf("%x", binary.BigEndian.Uint32(h[:]))
}

func inode(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

// unchanged reports whether the database file is still the one this dataset was loaded
// from. Sample order, key maps, clinical columns and cached probe columns all belong to
// that file: if it is replaced or rewritten, answers would mix two databases (values
// attached to the wrong samples). The server stops when this turns false; Docker starts it
// again and everything is loaded afresh. Replace a database by putting a NEW file or
// directory in place and restarting the service, never by copying over a served file.
func (d *Dataset) unchanged() bool {
	fi, err := os.Stat(d.Path)
	return err == nil && fi.Size() == d.fileSize && fi.ModTime().Equal(d.fileMtime) && inode(fi) == d.fileIno
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

// splitMeta reads a list stored in dataset_meta, as .split_meta() in dataset_registry.R does:
// separated by "|" (values can contain commas), or by "," when there is no "|" (older files).
func splitMeta(s string) []string {
	out := []string{}
	sep := ","
	if strings.Contains(s, "|") {
		sep = "|"
	}
	for _, p := range strings.Split(s, sep) {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// metaTrue: a dataset_meta flag is on for 1, true or yes (any case); anything else is off.
func metaTrue(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes":
		return true
	}
	return false
}

// loadRoles mirrors .resolve_roles(): dataset_meta, else introspection (the introspection
// step needs the clinical columns and is finished in loadClinical). The raw table is kept in
// d.meta: the api is the only interpreter of it.
func (d *Dataset) loadRoles() error {
	d.Defaults = map[string]string{"x": "cohort", "y": "", "color": "", "size": "", "condition": ""}
	d.Title, d.Label = d.Name, d.Name
	d.meta = map[string]string{}
	rows, err := d.db.Query("SELECT key, value FROM dataset_meta")
	if err != nil {
		d.Roles = Roles{CohortCol: "?"} // "?" = decide from the clinical column names
		return nil
	}
	defer rows.Close()
	m := d.meta
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
	d.Hidden = metaTrue(m["hidden"])
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
	if v := joinCohorts(m["default_cohorts"]); v != "" {
		d.Defaults["cohorts"] = v
	}
	d.sourceCol = m["source_col"]
	d.sourceLevels, d.sourceLabels, d.sourceDescs = splitMeta(m["sources"]), splitMeta(m["source_labels"]), splitMeta(m["source_descriptions"])
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
	if _, ok := byName["cohort"]; !ok {
		// a dataset that declares no cohort column still has the virtual `cohort`: one level, its label
		byName["cohort"] = cohortFromLabel(d.Label, len(sc))
		order = append(order, "cohort")
	}
	d.clin = map[string][]byte{}
	d.levels = map[string][]string{}
	d.clinText = map[string]textCol{}
	d.clinOrder = order
	d.clinNum = map[string]bool{}
	for _, n := range order {
		d.clinText[n] = textOf(byName[n])
		typ := clinicalTypeName(n)
		var levels []string
		if n == d.Roles.SampletypeCol && len(d.Roles.SampletypeLevels) > 0 {
			levels = d.Roles.SampletypeLevels
		}
		d.clinNum[n] = anyNumeric(byName[n], levels)
		d.clin[n] = encodeAny(n, typ, byName[n], levels)
		d.levels[n] = levelsOf(byName[n], levels)
	}
	// handles, in the order the menus use: subtype, cohort, sample type
	d.handles = makeHandles(d.Roles, have)
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

// loadTTE: the time-to-event variables. Declared in dataset_meta (a JSON array), else derived:
// every numeric clinical column X that has a numeric X.time.
func (d *Dataset) loadTTE() error {
	d.tte = []TTEVariable{}
	ok := func(v TTEVariable) bool { return v.Name != "" && d.clinNum[v.EventCol] && d.clinNum[v.TimeCol] }
	if raw := strings.TrimSpace(d.meta["tte_variables"]); raw != "" {
		var decl []TTEVariable
		if err := json.Unmarshal([]byte(raw), &decl); err != nil {
			log.Printf("%s: dataset_meta tte_variables is not a JSON array of objects (%v): none offered", d.Name, err)
			return nil
		}
		for _, v := range decl {
			if v.TimeUnit == "" {
				v.TimeUnit = "days"
			}
			if !ok(v) {
				log.Printf("%s: tte variable %q dropped: event_col %q / time_col %q not numeric clinical columns", d.Name, v.Name, v.EventCol, v.TimeCol)
				continue
			}
			d.tte = append(d.tte, v)
		}
		return nil
	}
	for _, x := range d.clinOrder {
		v := TTEVariable{Name: x, Label: x, EventCol: x, TimeCol: x + ".time", TimeUnit: "days"}
		if ok(v) {
			d.tte = append(d.tte, v)
		}
	}
	return nil
}

// sampleRows: sample name -> row index in the sample order.
func (d *Dataset) sampleRows() map[string]int32 {
	row := map[string]int32{}
	for i, s := range d.samples {
		row[s] = int32(i)
	}
	return row
}

func (d *Dataset) loadSamples() error {
	row := d.sampleRows()
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
	row := d.sampleRows()
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
		d.sparse[typ] = sparseType{sparse: !sp.Valid || sp.Int64 == 1, def: def.Float64}
	}
	return rows.Err()
}

func (d *Dataset) loadDatatypes() error {
	d.dtype = map[string]string{}
	d.typeLabels = map[string]string{}
	rows, err := d.db.Query("SELECT type, r_datatype FROM datatypes")
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var t string
			var r sql.NullString
			if err := rows.Scan(&t, &r); err != nil {
				return err
			}
			d.dtype[t] = r.String
			d.typeLabels[t] = t
		}
		if err := rows.Err(); err != nil {
			return err
		}
	} // optional table
	// types.label: the word a plot title uses for the type; the column may be missing
	d.hasLabel = d.hasColumn("types", "label")
	d.fillOpts = map[string][]string{}
	if d.hasColumn("types", "fill_options") { // optional column: older files have none
		if fr, err := d.db.Query("SELECT type, fill_options FROM types"); err == nil {
			for fr.Next() {
				var t string
				var f sql.NullString
				if fr.Scan(&t, &f) == nil {
					d.fillOpts[t] = parseFillOptions(f.String)
				}
			}
			fr.Close()
		}
	}
	q := "SELECT type, NULL FROM types"
	if d.hasLabel {
		q = "SELECT type, label FROM types"
	}
	if lr, err := d.db.Query(q); err == nil {
		defer lr.Close()
		for lr.Next() {
			var t string
			var l sql.NullString
			if err := lr.Scan(&t, &l); err != nil {
				return err
			}
			d.setTypeLabel(t, l)
		}
		return lr.Err()
	}
	return nil
}

var fillOrder = []string{"na", "zero", "floor"}

// parseFillOptions: the `|` list of types.fill_options, tolerant: unknown words and repeats
// are dropped, `na` is always first (an empty or NULL value is `na` only).
func parseFillOptions(v string) []string {
	have := map[string]bool{}
	for _, w := range strings.Split(v, "|") {
		have[strings.ToLower(strings.TrimSpace(w))] = true
	}
	out := []string{"na"}
	for _, f := range fillOrder[1:] {
		if have[f] {
			out = append(out, f)
		}
	}
	return out
}

// fillOptionsOf: the fills the data type lists (`na` only when it lists none).
func (d *Dataset) fillOptionsOf(typ string) []string {
	if o := d.fillOpts[typ]; len(o) > 0 {
		return o
	}
	return []string{"na"}
}

// fillOffers: does the data type list this fill?
func (d *Dataset) fillOffers(typ, fill string) bool {
	return slices.Contains(d.fillOpts[typ], fill) // fill is zero or floor here
}

// cohortIndex: the cohort of every sample row (the virtual `cohort` column, which is the
// roles' cohort column), as small integers, built once; the `floor` fill groups by it.
func (d *Dataset) cohortIndex() ([]int32, int) {
	d.cohortOnce.Do(func() {
		d.cohortIdx = make([]int32, len(d.samples))
		for i := range d.cohortIdx {
			d.cohortIdx[i] = -1
		}
		c, ok := d.clinText["cohort"]
		if !ok {
			return
		}
		ids := map[string]int32{}
		for i := range d.cohortIdx {
			if i >= len(c.val) || !c.ok[i] {
				continue
			}
			id, seen := ids[c.val[i]]
			if !seen {
				id = int32(len(ids))
				ids[c.val[i]] = id
			}
			d.cohortIdx[i] = id
		}
		d.nCohorts = len(ids)
	})
	return d.cohortIdx, d.nCohorts
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
		if n != "" {
			d.known[n] = struct{}{}
		}
		if n != "" && n != "sample" && !seen[n] {
			seen[n] = true
			d.probeNames = append(d.probeNames, n)
			d.probeLower = append(d.probeLower, strings.ToLower(n))
		}
	}
	for _, h := range d.handles {
		if h.Role == "subcohort" || h.Role == "cohort" {
			add(h.Name)
		}
	}
	for rows.Next() {
		var p sql.NullString
		if err := rows.Scan(&p); err != nil {
			return err
		}
		add(p.String)
	}
	for _, h := range d.handles {
		if h.Role == "sample_type" {
			add(h.Name)
		}
	}
	// clinical columns that are not in allprobes are still valid (survival times, ...)
	for _, n := range d.clinOrder {
		add(n)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	d.buildTyped(d.probeTypeCodes())
	// names with data that allprobes might not list (it is a superset in every build so far)
	prows, err := d.db.Query("SELECT probe FROM probes")
	if err != nil {
		return err
	}
	defer prows.Close()
	for prows.Next() {
		var p sql.NullString
		if err := prows.Scan(&p); err != nil {
			return err
		}
		if p.String != "" {
			d.known[p.String] = struct{}{}
		}
	}
	return prows.Err()
}

type probeType struct {
	typ string
	cat bool // categorical-only: no probe_types row, values in tcgacati
}

// probeTypeCodes: probe name -> its data type, from probe_types, else (a categorical-only
// probe) from tcgacati. Two queries at load; the result is dropped after the typed list is built.
func (d *Dataset) probeTypeCodes() map[string]probeType {
	out := map[string]probeType{}
	if rows, err := d.db.Query("SELECT p.probe, pt.type FROM probes p JOIN probe_types pt ON pt.probekey = p.key"); err == nil {
		for rows.Next() {
			var n, t sql.NullString
			if rows.Scan(&n, &t) == nil && n.Valid && t.Valid {
				out[n.String] = probeType{typ: t.String}
			}
		}
		rows.Close()
	}
	cati := map[int64]string{}
	if rows, err := d.db.Query("SELECT DISTINCT probekey, type FROM tcgacati"); err == nil {
		for rows.Next() {
			var k int64
			var t sql.NullString
			if rows.Scan(&k, &t) == nil && t.Valid {
				if _, dup := cati[k]; !dup {
					cati[k] = t.String
				}
			}
		}
		rows.Close()
	}
	if len(cati) > 0 {
		if rows, err := d.db.Query("SELECT key, probe FROM probes"); err == nil {
			for rows.Next() {
				var k int64
				var n sql.NullString
				if rows.Scan(&k, &n) == nil && n.Valid {
					if _, has := out[n.String]; has {
						continue
					}
					if t, ok := cati[k]; ok {
						out[n.String] = probeType{typ: t, cat: true}
					}
				}
			}
			rows.Close()
		}
	}
	return out
}

// isKnown: is this name a variable of the dataset at all? Answered from memory, before any
// query and before the cache, so made-up names cost nothing.
func (d *Dataset) isKnown(name string) bool {
	if _, ok := d.clin[name]; ok {
		return true
	}
	_, ok := d.known[name]
	return ok
}

// a column's raw values as text, with which rows have one (the preset rules and the data
// sources are evaluated on these, as default_filters.R and gitr() evaluate them in R)
type textCol struct {
	val []string
	ok  []bool
}

func textOf(vals []any) textCol {
	c := textCol{val: make([]string, len(vals)), ok: make([]bool, len(vals))}
	for i, v := range vals {
		switch x := v.(type) {
		case nil:
		case string:
			c.val[i], c.ok[i] = x, true
		case float64:
			c.val[i], c.ok[i] = rNumber(x), true
		default:
			c.val[i], c.ok[i] = fmt.Sprint(x), true
		}
	}
	return c
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
	NSamples    int          `json:"n_samples"` // samples of the whole dataset in the preset
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
	defer d.ensureHemePreset()
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
		if !known || (op != "in" && op != "not in") || !slices.Contains(lv, val) {
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

func (d *Dataset) derivePresets() {
	if st := d.Roles.SampletypeCol; st != "" {
		if v := d.knownLevels(st, d.Roles.NormalLabel); len(v) > 0 {
			d.presets = append(d.presets, Preset{Label: "Exclude non-tumor", Description: "Tumor samples only", Source: "derived",
				Rules: []PresetRule{{Column: st, Op: "not in", Values: v}}})
		}
	}
	d.ensureHemePreset()
}

// ensureHemePreset adds the classic "Exclude tumors of heme origin" from the role map's
// heme values when the dataset's own presets do not already drop cohorts: the choice
// belongs to every collection with blood or lymphoid cohorts (TCGA, TARGET, GTEx), whether
// or not its default_filters table thought of it.
func (d *Dataset) ensureHemePreset() {
	for _, p := range d.presets {
		for _, r := range p.Rules {
			if r.Column == "cohort" && r.Op == "not in" {
				return
			}
		}
	}
	if v := d.knownLevels("cohort", d.Roles.HemeValues); len(v) > 0 {
		d.presets = append(d.presets, Preset{Label: "Exclude tumors of heme origin", Description: "Drop blood and lymphoid cohorts", Source: "derived",
			Rules: []PresetRule{{Column: "cohort", Op: "not in", Values: v}}})
	}
}

// knownLevels: the values among vals that are levels of the column (none if the column is unknown)
func (d *Dataset) knownLevels(col string, vals []string) []string {
	out := []string{}
	for _, v := range vals {
		if slices.Contains(d.levels[col], v) {
			out = append(out, v)
		}
	}
	return out
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
	cols := "type, description, example, reference, source_file, source_url"
	if d.hasLabel {
		cols += ", COALESCE(label, '') AS label"
	}
	types := table("SELECT " + cols + " FROM types ORDER BY type")
	if len(types) == 0 {
		types = table("SELECT type FROM types ORDER BY type")
	}
	if !d.hasLabel {
		for _, row := range types {
			row["label"] = ""
		}
	}
	for _, row := range types {
		d.joinReference(row)
		t, _ := row["type"].(string)
		row["fill_options"] = d.fillOptionsOf(t)
	}
	survival := []string{}
	for _, v := range d.tte {
		survival = append(survival, v.Name)
	}
	meta := metaDoc{
		DatasetSummary:       d.summary(),
		Dataset:              d.Name,
		Presets:              d.presets,
		ClinicalColumns:      d.clinOrder,
		ClinicalDescriptions: clinicalDescriptions(d.Name, d.clinOrder),
		SurvivalEndpoints:    survival,
		TTEVariables:         d.tte,
		TypeLabels:           d.typeLabels,
		About: map[string]any{"description": d.meta["about"], "citation": d.meta["citation"],
			"attribution": d.meta["attribution"], "url": d.meta["about_url"], "references": d.references},
		DefaultCohorts: splitMeta(d.meta["default_cohorts"]),
		Cohorts:        table("SELECT * FROM cohorts"),
		Types:          types,
		Datatypes:      d.dtype,
	}
	var err error
	d.metaJSON, err = json.Marshal(meta)
	if err != nil {
		return err
	}
	// every selectable name, for a client that fills its own menus (the R app's selectize),
	// with the typed arrays (section / type / kind codes, parallel to probes)
	sec, typ, kind := make([]int, len(d.probeNames)), make([]int, len(d.probeNames)), make([]int, len(d.probeNames))
	for i := range d.probeNames {
		sec[i], typ[i], kind[i] = int(d.typedSection[i]), int(d.typedType[i]), int(d.typedKind[i])
	}
	d.probesJSON, err = json.Marshal(map[string]any{"dataset": d.Name, "version": d.version,
		"n": len(d.probeNames), "probes": d.probeNames, "types": d.typedTypes, "section": sec, "type": typ, "kind": kind})
	return err
}

// DatasetSummary: what /v1/datasets lists for each dataset and /v1/{ds}/meta starts with.
type DatasetSummary struct {
	Name     string            `json:"name"`
	Title    string            `json:"title"`
	Label    string            `json:"label"`
	Samples  int               `json:"n_samples"`
	Probes   int               `json:"n_probes"`
	Version  string            `json:"version"`
	Roles    Roles             `json:"roles"`
	Defaults map[string]string `json:"defaults"`
	Sources  []Source          `json:"sources"` // the whole collection and its parts, for the data-source menu
	Handles  []Handle          `json:"handles"`
	Hidden   bool              `json:"hidden"` // not for the apps' lists (e.g. DEMO); always present
}

func (d *Dataset) summary() DatasetSummary {
	return DatasetSummary{d.Name, d.Title, d.Label, len(d.samples), len(d.probeNames), d.version, d.Roles, d.Defaults, d.sources, d.handles, d.Hidden}
}

// metaDoc is the /v1/{ds}/meta document; fields are only ever added.
type metaDoc struct {
	DatasetSummary
	Dataset              string            `json:"dataset"`
	Presets              []Preset          `json:"presets"`
	ClinicalColumns      []string          `json:"clinical_columns"`
	ClinicalDescriptions any               `json:"clinical_descriptions"`
	SurvivalEndpoints    []string          `json:"survival_endpoints"`
	TTEVariables         []TTEVariable     `json:"tte_variables"`
	TypeLabels           map[string]string `json:"type_labels"`
	About                map[string]any    `json:"about"`
	DefaultCohorts       []string          `json:"default_cohorts"` // the array form: names can contain commas
	Cohorts              []map[string]any  `json:"cohorts"`
	Types                []map[string]any  `json:"types"`
	Datatypes            map[string]string `json:"datatypes"`
}

// ---------------------------------------------------------------------------------------
// one column

// columnFill returns the encoded JSON object for one name (nil if the dataset has no such
// variable) with the fill applied (see fetchProbe). Probe columns are cached; concurrent
// requests for the same probe share one query. A probe whose data type does not list
// the fill is served unchanged, and aux tells the caller whether the fill was applied
// (aux.filled counts the cells changed; applied = the type lists it).
func (d *Dataset) columnFill(name, fill string) (col []byte, aux colAux, err error) {
	if c, ok := d.clin[name]; ok {
		return c, colAux{}, nil
	}
	if _, ok := d.known[name]; !ok {
		return nil, colAux{}, nil // not a variable of this dataset: no query, no cache entry
	}
	col, aux, err = d.cache.get(d.Name+"\x00"+name, func() ([]byte, colAux, error) { return d.fetchProbe(name, "na") })
	if err != nil || col == nil || fill == "na" || aux.typ == "" || !d.fillOffers(aux.typ, fill) {
		return col, aux, err
	}
	return d.cache.get(d.Name+"\x00"+name+"|"+fill, func() ([]byte, colAux, error) { return d.fetchProbe(name, fill) })
}

// fetchProbe reads one variable. fill is "na", "zero" or "floor": for a numeric probe of a
// type loaded in full (sparse = 0), a sample that is TESTED for the type but has no stored
// row is missing (na), 0 (zero) or the smallest stored value of the probe among the tested
// samples of the same cohort, else of the whole dataset (floor). Samples not tested, and
// stored values (NULL included), are never changed.
func (d *Dataset) fetchProbe(name, fill string) ([]byte, colAux, error) {
	var key int64
	err := d.db.QueryRow("SELECT key FROM probes WHERE probe = ?", name).Scan(&key)
	if err == sql.ErrNoRows {
		return nil, colAux{}, nil
	}
	if err != nil {
		return nil, colAux{}, err
	}
	n := len(d.samples)
	var typ sql.NullString
	err = d.db.QueryRow("SELECT type FROM probe_types WHERE probekey = ? ORDER BY rowid LIMIT 1", key).Scan(&typ)
	if err != nil && err != sql.ErrNoRows {
		return nil, colAux{}, err
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
		doFill := fill != "na" && !st.sparse && tested != nil && d.fillOffers(typ.String, fill)
		var stored []bool // rows with a stored value or NULL (only kept for a fill)
		var cohort []int32
		var cmin []float64 // floor: smallest stored value per cohort
		gmin := math.Inf(1)
		if doFill {
			stored = make([]bool, n)
			if fill == "floor" {
				var nc int
				cohort, nc = d.cohortIndex()
				cmin = make([]float64, nc)
				for i := range cmin {
					cmin[i] = math.Inf(1)
				}
			}
		}
		rows, err := d.db.Query("SELECT samplekey, value FROM tcgai WHERE probekey = ? AND type = ?", key, typ.String)
		if err != nil {
			return nil, colAux{}, err
		}
		defer rows.Close()
		for rows.Next() {
			var sk int64
			var v sql.NullFloat64
			if err := rows.Scan(&sk, &v); err != nil {
				return nil, colAux{}, err
			}
			r, ok := d.keyToRow[sk]
			if !ok || tested == nil || !tested[r] {
				continue
			}
			if doFill {
				stored[r] = true
			}
			if v.Valid {
				vals[r] = v.Float64
				if cmin != nil && !math.IsNaN(v.Float64) && !math.IsInf(v.Float64, 0) {
					gmin = math.Min(gmin, v.Float64)
					if c := cohort[r]; c >= 0 {
						cmin[c] = math.Min(cmin[c], v.Float64)
					}
				}
			} else {
				vals[r] = math.NaN() // stored NULL: genuinely missing
			}
		}
		if err := rows.Err(); err != nil {
			return nil, colAux{}, err
		}
		aux := colAux{typ: typ.String}
		for _, t := range tested {
			if t {
				aux.testedN++
			}
		}
		if doFill { // second pass: the tested samples without a stored row
			for r := range vals {
				if !tested[r] || stored[r] {
					continue
				}
				switch fill {
				case "zero":
					vals[r] = 0
					aux.filled++
				case "floor":
					f := gmin // a cohort with no stored value: the probe's dataset-wide minimum
					if c := cohort[r]; c >= 0 && !math.IsInf(cmin[c], 1) {
						f = cmin[c]
					}
					if !math.IsInf(f, 1) { // a probe with no stored value at all stays missing
						vals[r] = f
						aux.filled++
					}
				}
			}
		}
		if d.declaredType(name, typ.String) == "factor" {
			return encodeNumAsCat(name, typ.String, vals), aux, nil
		}
		return encodeNum(name, typ.String, vals), aux, nil
	}
	// categorical probe
	rows, err := d.db.Query("SELECT samplekey, value, type FROM tcgacati WHERE probekey = ?", key)
	if err != nil {
		return nil, colAux{}, err
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
			return nil, colAux{}, err
		}
		found = true
		ctype = t.String
		if r, ok := d.keyToRow[sk]; ok && v.Valid && (!has[r] || v.String < raw[r]) {
			raw[r], has[r] = v.String, true
		}
	}
	if err := rows.Err(); err != nil {
		return nil, colAux{}, err
	}
	if !found {
		return nil, colAux{}, nil
	}
	vals := make([]any, n)
	for r := range raw {
		if has[r] {
			vals[r] = cleanText(raw[r])
		}
	}
	return encodeAny(name, ctype, vals, nil), colAux{}, nil
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

// anyNumeric: the rule encodeAny uses -- numeric iff some value is present and every present
// value is a number (and no fixed level order is given).
func anyNumeric(vals []any, fixedLevels []string) bool {
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
	return numeric && present
}

// encodeAny encodes a column read as raw database values: numeric if every present value is
// a number, else categorical. fixedLevels, if given, is the level order to use; values
// outside it are missing.
func encodeAny(name, typ string, vals []any, fixedLevels []string) []byte {
	if anyNumeric(vals, fixedLevels) {
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

type typedHit struct {
	Name    string `json:"name"`
	Section string `json:"section"` // handle | probe | clinical
	Type    string `json:"type"`
	Kind    string `json:"kind"` // num | cat
}

var sectionNames = [...]string{"handle", "probe", "clinical"}

// typedHits: the typed fields of search hits (indexes into probeNames), as words
func (d *Dataset) typedHits(idx []int) []typedHit {
	out := make([]typedHit, 0, len(idx))
	for _, i := range idx {
		h := typedHit{Name: d.probeNames[i], Section: sectionNames[d.typedSection[i]],
			Type: d.typedTypes[d.typedType[i]], Kind: "num"}
		if d.typedKind[i] == 1 {
			h.Kind = "cat"
		}
		out = append(out, h)
	}
	return out
}

// joinCohorts: the file stores default_cohorts as a "|" list (older files: commas); the api serves commas.
func joinCohorts(v string) string { return strings.Join(splitMeta(v), ",") }

// setTypeLabel records types.label: NULL (or no column) = the type name, "" stays "".
func (d *Dataset) setTypeLabel(t string, l sql.NullString) {
	if l.Valid {
		d.typeLabels[t] = cleanText(l.String)
	} else if _, ok := d.typeLabels[t]; !ok {
		d.typeLabels[t] = t
	}
}

// makeHandles: subtype (sub-cohort), cohort, sample type -- the declared columns that exist.
// `cohort` always exists (see loadClinical).
func makeHandles(r Roles, have map[string]bool) []Handle {
	h := []Handle{}
	if c := r.SubtypeCol; c != "" && have[c] {
		h = append(h, Handle{"subtype", "subcohort"})
	}
	h = append(h, Handle{"cohort", "cohort"})
	if c := r.SampletypeCol; c != "" && have[c] {
		h = append(h, Handle{c, "sample_type"})
	}
	return h
}

func cohortFromLabel(label string, n int) []any {
	lab := make([]any, n)
	for i := range lab {
		lab[i] = label
	}
	return lab
}

// buildTyped fills the parallel arrays of the typed variable list (section, type code, kind)
// for d.probeNames, from the clinical columns and the probe types.
func (d *Dataset) buildTyped(ptypes map[string]probeType) {
	typeCode := map[string]uint16{}
	code := func(t string) uint16 {
		c, ok := typeCode[t]
		if !ok {
			c = uint16(len(d.typedTypes))
			d.typedTypes = append(d.typedTypes, t)
			typeCode[t] = c
		}
		return c
	}
	isHandle := map[string]bool{}
	for _, h := range d.handles {
		isHandle[h.Name] = true
	}
	d.typedSection, d.typedType, d.typedKind, d.typedTypes = nil, nil, nil, nil
	for _, n := range d.probeNames {
		var sec, kind uint8 = 1, 0
		var typ string
		if _, isClin := d.clin[n]; isClin {
			sec, typ = 2, clinicalTypeName(n)
			if !d.clinNum[n] {
				kind = 1
			}
		} else if pt, ok := ptypes[n]; ok {
			typ = pt.typ
			if pt.cat || d.declaredType(n, pt.typ) == "factor" {
				kind = 1
			}
		} else {
			typ = "unknown"
			if d.declaredType(n, typ) == "factor" {
				kind = 1
			}
		}
		if isHandle[n] {
			sec = 0
		}
		d.typedSection = append(d.typedSection, sec)
		d.typedType = append(d.typedType, code(typ))
		d.typedKind = append(d.typedKind, kind)
	}
}

func isVirtualColumn(n string) bool { return n == "cohort" || n == "subtype" || n == "lcohort" }

// clinicalTypeName: the type label of a clinical column ("virtual" for the added ones).
func clinicalTypeName(n string) string {
	if isVirtualColumn(n) {
		return "virtual"
	}
	return "clinical"
}

// hasColumn: does the table have this column? (PRAGMA table_info)
func (d *Dataset) hasColumn(table, col string) bool {
	rows, err := d.db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		return false
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notnull, pk int
		var name, ctype string
		var dflt sql.NullString
		if rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk) == nil && name == col {
			return true
		}
	}
	return false
}
