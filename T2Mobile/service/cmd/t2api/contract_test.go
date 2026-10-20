package main

import (
	"database/sql"
	"encoding/json"
	"reflect"
	"testing"
)

// a toy dataset with clinical columns, built without a database: the same loadTTE and
// handle rules as production run on d.clin / d.clinNum / d.meta.
func tteFixture(meta map[string]string, cols map[string]bool) *Dataset {
	d := &Dataset{Name: "toy", Label: "Toy", meta: meta, clin: map[string][]byte{}, clinNum: cols}
	for _, n := range []string{"OS", "OS.time", "PFI", "gender", "DSS", "DSS.time", "DSS.txt"} {
		if v, ok := cols[n]; ok {
			d.clinOrder = append(d.clinOrder, n)
			d.clin[n] = nil
			_ = v
		}
	}
	return d
}

func toyCols() map[string]bool {
	return map[string]bool{"OS": true, "OS.time": true, "PFI": true, "gender": false, "DSS": true, "DSS.time": false}
}

func names(v []TTEVariable) []string {
	out := []string{}
	for _, x := range v {
		out = append(out, x.Name)
	}
	return out
}

func TestTTEDerived(t *testing.T) {
	d := tteFixture(map[string]string{}, toyCols())
	d.loadTTE()
	// OS+OS.time numeric: yes; PFI has no PFI.time: no; DSS.time is not numeric: no
	if got := names(d.tte); !reflect.DeepEqual(got, []string{"OS"}) {
		t.Fatalf("derived: %v", got)
	}
	if v := d.tte[0]; v.EventCol != "OS" || v.TimeCol != "OS.time" || v.TimeUnit != "days" || v.Label != "OS" {
		t.Errorf("derived entry: %+v", v)
	}
}

func TestTTEDeclaredDropsInvalid(t *testing.T) {
	decl := `[{"name":"OS","label":"Overall Survival","event_col":"OS","time_col":"OS.time","time_unit":"days","description":"d"},
	 {"name":"BAD1","label":"x","event_col":"nope","time_col":"OS.time","time_unit":"days"},
	 {"name":"BAD2","label":"x","event_col":"gender","time_col":"OS.time","time_unit":"days"},
	 {"name":"BAD3","label":"x","event_col":"OS","time_col":"gender","time_unit":"days"}]`
	d := tteFixture(map[string]string{"tte_variables": decl}, toyCols())
	d.loadTTE()
	if got := names(d.tte); !reflect.DeepEqual(got, []string{"OS"}) {
		t.Fatalf("declared: %v", got)
	}
	if d.tte[0].Label != "Overall Survival" {
		t.Errorf("label: %+v", d.tte[0])
	}
}

func TestTTEEmptyIsNotNil(t *testing.T) {
	d := tteFixture(map[string]string{"tte_variables": "[]"}, toyCols())
	d.loadTTE()
	if d.tte == nil || len(d.tte) != 0 {
		t.Fatalf("want empty non-nil, got %#v", d.tte)
	}
	d2 := tteFixture(map[string]string{}, map[string]bool{"gender": false})
	d2.loadTTE()
	if d2.tte == nil {
		t.Fatal("derived: nil")
	}
	// and the meta JSON carries [] not null
	d2.db = nil
	b, _ := json.Marshal(map[string]any{"tte_variables": d2.tte})
	if string(b) != `{"tte_variables":[]}` {
		t.Errorf("json: %s", b)
	}
}

func TestNormalizeCohorts(t *testing.T) {
	for in, want := range map[string]string{"A|B": "A,B", "A,B": "A,B", " A | B ": "A,B", "": ""} {
		if got := joinCohorts(in); got != want {
			t.Errorf("%q: got %q want %q", in, got, want)
		}
	}
}

func TestTypeLabelFallback(t *testing.T) {
	d := &Dataset{typeLabels: map[string]string{}}
	d.setTypeLabel("mut", sqlStr("mutation"))
	d.setTypeLabel("rna", sqlStr(""))
	d.setTypeLabel("cnv", sqlNull())
	if d.typeLabels["mut"] != "mutation" || d.typeLabels["rna"] != "" || d.typeLabels["cnv"] != "cnv" {
		t.Errorf("labels: %v", d.typeLabels)
	}
}

func TestHandles(t *testing.T) {
	with := &Dataset{Roles: Roles{SubtypeCol: "st", SampletypeCol: "sample_type"}}
	with.handles = makeHandles(with.Roles, map[string]bool{"st": true, "sample_type": true})
	want := []Handle{{"subtype", "subcohort"}, {"cohort", "cohort"}, {"sample_type", "sample_type"}}
	if !reflect.DeepEqual(with.handles, want) {
		t.Errorf("with subtype: %v", with.handles)
	}
	without := makeHandles(Roles{}, map[string]bool{})
	if !reflect.DeepEqual(without, []Handle{{"cohort", "cohort"}}) {
		t.Errorf("without: %v", without)
	}
	// declared but absent columns are not handles
	if h := makeHandles(Roles{SubtypeCol: "gone", SampletypeCol: "gone2"}, map[string]bool{}); len(h) != 1 {
		t.Errorf("absent: %v", h)
	}
}

func TestSynthesizedCohortColumn(t *testing.T) {
	vals := cohortFromLabel("Toy", 3)
	if len(vals) != 3 || vals[0] != "Toy" || vals[2] != "Toy" {
		t.Errorf("synth: %v", vals)
	}
	if anyNumeric(vals, nil) {
		t.Error("synthesized cohort must be categorical")
	}
}

func TestTypedListConsistent(t *testing.T) {
	d := &Dataset{Name: "toy", dtype: map[string]string{"mut": "factor", "rna": "numeric"},
		clin: map[string][]byte{"cohort": nil, "age": nil, "gender": nil}, clinNum: map[string]bool{"cohort": false, "age": true, "gender": false}}
	d.handles = []Handle{{"cohort", "cohort"}}
	d.probeNames = []string{"cohort", "TP53", "TP53.mut", "age", "gender", "X"}
	ptypes := map[string]probeType{"TP53": {typ: "rna"}, "TP53.mut": {typ: "mut"}}
	d.buildTyped(ptypes)
	n := len(d.probeNames)
	if len(d.typedSection) != n || len(d.typedType) != n || len(d.typedKind) != n {
		t.Fatalf("lengths %d %d %d vs %d", len(d.typedSection), len(d.typedType), len(d.typedKind), n)
	}
	for i := 0; i < n; i++ {
		if d.typedSection[i] > 2 || int(d.typedType[i]) >= len(d.typedTypes) || d.typedKind[i] > 1 {
			t.Errorf("code out of range at %d", i)
		}
	}
	h := d.typedHits([]int{0, 1, 2, 3, 5})
	got := [][4]string{}
	for _, x := range h {
		got = append(got, [4]string{x.Name, x.Section, x.Type, x.Kind})
	}
	want := [][4]string{{"cohort", "handle", "virtual", "cat"}, {"TP53", "probe", "rna", "num"}, {"TP53.mut", "probe", "mut", "cat"},
		{"age", "clinical", "clinical", "num"}, {"X", "probe", "unknown", "num"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("hits: %v", got)
	}
}

func sqlStr(s string) sql.NullString { return sql.NullString{String: s, Valid: true} }
func sqlNull() sql.NullString        { return sql.NullString{} }

func TestDatasetFilesAndOrder(t *testing.T) {
	names := func(f []datasetFile) []string {
		o := []string{}
		for _, x := range f {
			o = append(o, x.name+"="+x.path)
		}
		return o
	}
	if got := names(datasetFiles("/d/tcga.db", []string{"/x/cptac.db"})); !reflect.DeepEqual(got, []string{"TCGA=/d/tcga.db", "cptac=/x/cptac.db"}) {
		t.Errorf("flag only: %v", got)
	}
	if got := names(datasetFiles("", []string{"/x/TCGA.db", "/x/cptac.db"})); !reflect.DeepEqual(got, []string{"TCGA=/x/TCGA.db", "cptac=/x/cptac.db"}) {
		t.Errorf("datasets only: %v", got)
	}
	if got := names(datasetFiles("/d/tcga.db", []string{"/x/TCGA.db"})); !reflect.DeepEqual(got, []string{"TCGA=/x/TCGA.db"}) {
		t.Errorf("both: %v", got)
	}
	ord := map[string]int{"TCGA": 1, "zeta": 2}
	got := orderDatasets([]string{"cptac", "zeta", "Toil", "TCGA"}, func(n string) (int, bool) { v, ok := ord[n]; return v, ok })
	if !reflect.DeepEqual(got, []string{"TCGA", "zeta", "Toil", "cptac"}) {
		t.Errorf("order: %v", got)
	}
}
