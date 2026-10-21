package main

import (
	"database/sql"
	"encoding/json"
	"math"
	"net/http/httptest"
	"reflect"
	"testing"
)

// a toy dataset over an in-memory database: six samples in cohorts A (s1-s3) and B (s4-s6);
// s6 is not tested for prot. Types: prot offers na|zero|floor, rna only na.
//
//	P.prot  s1=5 s2=3 (A), s4 missing, s5=8 (B), s3 missing   -> tested, no row: s3, s4
//	Q.prot  s1 stored NULL, s2..s5 no rows at all             -> no stored value anywhere
//	R.prot  s1=2 s2=4 s3=6 (A) only; B has no stored value    -> floor of B falls back to 2
//	G.rna   all tested, values stored for s1, s2
func fillFixture(t *testing.T, withColumn bool) *Dataset {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	ddl := []string{
		"CREATE TABLE probes (key INTEGER, probe TEXT)",
		"CREATE TABLE probe_types (probekey INTEGER, type TEXT)",
		"CREATE TABLE tcgai (probekey INTEGER, samplekey INTEGER, type TEXT, value REAL)",
		"INSERT INTO probes VALUES (1,'P.prot'),(2,'Q.prot'),(3,'R.prot'),(4,'G.rna')",
		"INSERT INTO probe_types VALUES (1,'prot'),(2,'prot'),(3,'prot'),(4,'rna')",
		"INSERT INTO tcgai VALUES (1,1,'prot',5),(1,2,'prot',3),(1,5,'prot',8),(1,6,'prot',99)", // s6 untested: ignored
		"INSERT INTO tcgai VALUES (2,1,'prot',NULL)",
		"INSERT INTO tcgai VALUES (3,1,'prot',2),(3,2,'prot',4),(3,3,'prot',6)",
		"INSERT INTO tcgai VALUES (4,1,'rna',1.5),(4,2,'rna',2.5)",
	}
	if withColumn {
		ddl = append(ddl, "CREATE TABLE types (type TEXT, fill_options TEXT)",
			"INSERT INTO types VALUES ('prot','na|zero|floor'),('rna','na')")
	} else {
		ddl = append(ddl, "CREATE TABLE types (type TEXT)", "INSERT INTO types VALUES ('prot'),('rna')")
	}
	for _, q := range ddl {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(q, err)
		}
	}
	d := &Dataset{Name: "toy", Label: "Toy", db: db, version: "v1", cache: newColumnCache(1 << 20)}
	d.samples = []string{"s1", "s2", "s3", "s4", "s5", "s6"}
	d.keyToRow = map[int64]int32{1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5}
	d.tested = map[string][]bool{
		"prot": {true, true, true, true, true, false},
		"rna":  {true, true, true, true, true, true},
	}
	d.sparse = map[string]sparseType{"prot": {sparse: false}, "rna": {sparse: false}}
	d.dtype = map[string]string{}
	d.clin = map[string][]byte{}
	d.clinText = map[string]textCol{"cohort": {val: []string{"A", "A", "A", "B", "B", "B"}, ok: []bool{true, true, true, true, true, true}}}
	d.known = map[string]struct{}{"P.prot": {}, "Q.prot": {}, "R.prot": {}, "G.rna": {}}
	if err := d.loadDatatypes(); err != nil {
		t.Fatal(err)
	}
	return d
}

type valuesAnswer struct {
	Columns []struct {
		Name   string     `json:"name"`
		Values []*float64 `json:"values"`
	} `json:"columns"`
	FillOptions []string       `json:"fill_options"`
	Fill        string         `json:"fill"`
	Filled      map[string]int `json:"filled"`
	TestedN     map[string]int `json:"tested_n"`
}

func getValues(t *testing.T, d *Dataset, query string) (int, valuesAnswer, string) {
	s := &server{datasets: map[string]*Dataset{"toy": d}}
	rec := httptest.NewRecorder() // the handler itself: withDataset checks the file on disk, which a toy lacks
	s.handleValues(rec, httptest.NewRequest("GET", "/v1/toy/values?"+query, nil), d)
	var a valuesAnswer
	if rec.Code == 200 {
		if err := json.Unmarshal(rec.Body.Bytes(), &a); err != nil {
			t.Fatalf("%s: %v\n%s", query, err, rec.Body.String())
		}
	}
	return rec.Code, a, rec.Header().Get("ETag")
}

// vals: a column as floats, NaN for null
func (a valuesAnswer) vals(name string) []float64 {
	for _, c := range a.Columns {
		if c.Name == name {
			out := make([]float64, len(c.Values))
			for i, p := range c.Values {
				out[i] = math.NaN()
				if p != nil {
					out[i] = *p
				}
			}
			return out
		}
	}
	return nil
}

func same(a, b []float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !(a[i] == b[i] || (math.IsNaN(a[i]) && math.IsNaN(b[i]))) {
			return false
		}
	}
	return true
}

func TestFillOptionsLoaded(t *testing.T) {
	d := fillFixture(t, true)
	if !reflect.DeepEqual(d.fillOptionsOf("prot"), []string{"na", "zero", "floor"}) || !reflect.DeepEqual(d.fillOptionsOf("rna"), []string{"na"}) {
		t.Errorf("options: %v", d.fillOpts)
	}
	if got := parseFillOptions("floor| Zero |bogus|zero"); !reflect.DeepEqual(got, []string{"na", "zero", "floor"}) {
		t.Errorf("parse: %v", got)
	}
	if got := parseFillOptions(""); !reflect.DeepEqual(got, []string{"na"}) {
		t.Errorf("empty: %v", got)
	}
	e := fillFixture(t, false) // no column: na only
	if !reflect.DeepEqual(e.fillOptionsOf("prot"), []string{"na"}) {
		t.Errorf("no column: %v", e.fillOptionsOf("prot"))
	}
}

func TestFillZeroAndFloor(t *testing.T) {
	d := fillFixture(t, true)
	nan := math.NaN()
	code, na, etagNA := getValues(t, d, "probes=P.prot,G.rna")
	if code != 200 || !same(na.vals("P.prot"), []float64{5, 3, nan, nan, 8, nan}) || na.Fill != "" || na.Filled != nil {
		t.Fatalf("na answer: %d %+v", code, na)
	}
	if !reflect.DeepEqual(na.FillOptions, []string{"na", "zero", "floor"}) {
		t.Errorf("na fill_options: %v", na.FillOptions)
	}

	code, z, etagZ := getValues(t, d, "probes=P.prot,G.rna&fill=zero")
	if code != 200 || z.Fill != "zero" {
		t.Fatalf("zero: %d %+v", code, z)
	}
	// s3, s4 filled; s6 untested stays NaN; stored values unchanged; the rna probe is served unchanged
	if !same(z.vals("P.prot"), []float64{5, 3, 0, 0, 8, nan}) {
		t.Errorf("zero P.prot: %v", z.vals("P.prot"))
	}
	if !same(z.vals("G.rna"), na.vals("G.rna")) {
		t.Errorf("rna changed by fill=zero: %v", z.vals("G.rna"))
	}
	if !reflect.DeepEqual(z.Filled, map[string]int{"P.prot": 2}) || !reflect.DeepEqual(z.TestedN, map[string]int{"P.prot": 5}) {
		t.Errorf("filled %v tested_n %v", z.Filled, z.TestedN)
	}
	if etagNA == "" || etagNA == etagZ {
		t.Errorf("ETag must differ by fill: %q %q", etagNA, etagZ)
	}

	// floor: P.prot cohort A min 3 (s3 -> 3), cohort B min 8 (s4 -> 8); R.prot: B has none -> dataset min 2;
	// Q.prot has no stored value anywhere (only a NULL, which stays) -> nothing is filled
	code, f, _ := getValues(t, d, "probes=P.prot,R.prot,Q.prot&fill=floor")
	if code != 200 {
		t.Fatal(code)
	}
	if !same(f.vals("P.prot"), []float64{5, 3, 3, 8, 8, nan}) {
		t.Errorf("floor P.prot: %v", f.vals("P.prot"))
	}
	if !same(f.vals("R.prot"), []float64{2, 4, 6, 2, 2, nan}) {
		t.Errorf("floor R.prot (dataset-wide fallback): %v", f.vals("R.prot"))
	}
	if !same(f.vals("Q.prot"), []float64{nan, nan, nan, nan, nan, nan}) {
		t.Errorf("floor Q.prot: %v", f.vals("Q.prot"))
	}
	if !reflect.DeepEqual(f.Filled, map[string]int{"P.prot": 2, "R.prot": 2}) || f.Fill != "floor" {
		t.Errorf("floor filled %v", f.Filled)
	}
	// a stored value is never replaced: the stored 99 for the untested s6 stays out, a stored NULL stays NaN
	code, z2, _ := getValues(t, d, "probes=Q.prot&fill=zero")
	if code != 200 || !same(z2.vals("Q.prot"), []float64{nan, 0, 0, 0, 0, nan}) {
		t.Errorf("zero Q.prot: %d %v", code, z2.vals("Q.prot"))
	}
}

func TestFillErrorsAndUnion(t *testing.T) {
	d := fillFixture(t, true)
	if code, _, _ := getValues(t, d, "probes=P.prot&fill=bogus"); code != 400 {
		t.Errorf("bad fill: %d", code)
	}
	if code, _, _ := getValues(t, d, "probes=G.rna&fill=zero"); code != 400 {
		t.Errorf("fill on rna only: %d", code)
	}
	code, a, _ := getValues(t, d, "probes=G.rna")
	if code != 200 || !reflect.DeepEqual(a.FillOptions, []string{"na"}) || a.Fill != "" {
		t.Errorf("rna only: %d %v", code, a.FillOptions)
	}
	// a request with a probe that cannot be filled next to one that can: fine, only the latter changes
	if code, a, _ := getValues(t, d, "probes=G.rna,R.prot&fill=zero"); code != 200 || len(a.Filled) != 1 {
		t.Errorf("mixed: %d %v", code, a.Filled)
	}

	e := fillFixture(t, false) // no fill_options column anywhere
	code, a, _ = getValues(t, e, "probes=P.prot,G.rna")
	if code != 200 || !reflect.DeepEqual(a.FillOptions, []string{"na"}) {
		t.Errorf("no column: %d %v", code, a.FillOptions)
	}
	if code, _, _ := getValues(t, e, "probes=P.prot&fill=zero"); code != 400 {
		t.Errorf("fill without column: %d", code)
	}
}
