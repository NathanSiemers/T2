package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

const refsJSON = `[
 {"group":"G1","title":"Paper A","authors":"A B","journal":"Cell","year":2018,"pmid":"111","doi":"10.1/a","url":"http://x/a","note":"n"},
 {"group":"G1","title":"","authors":"nobody","journal":"J","year":2000,"pmid":"999"},
 {"group":"G2","title":"Paper B","authors":"C D","journal":"Nature","year":2020,"doi":"10.1038/B.2","url":"http://x/b"},
 {"group":"G2","title":"Paper C","year":2021,"url":"http://x/c"}
]`

func refFixture(raw string) *Dataset {
	m := map[string]string{}
	if raw != "" {
		m["references"] = raw
	}
	d := &Dataset{Name: "toy", meta: m}
	d.loadReferences()
	return d
}

func TestReferencesParse(t *testing.T) {
	d := refFixture(refsJSON)
	var titles, urls []string
	for _, r := range d.references {
		titles, urls = append(titles, r.Title), append(urls, r.URL)
	}
	if !reflect.DeepEqual(titles, []string{"Paper A", "Paper B", "Paper C"}) {
		t.Errorf("titles (untitled dropped, order kept): %v", titles)
	}
	want := []string{"https://pubmed.ncbi.nlm.nih.gov/111/", "https://doi.org/10.1038/B.2", "http://x/c"}
	if !reflect.DeepEqual(urls, want) {
		t.Errorf("urls: %v want %v", urls, want)
	}
	if d.references[2].Authors != "" || d.references[2].Journal != "" || d.references[0].Group != "G1" {
		t.Errorf("fields: %+v", d.references)
	}
}

func TestReferencesAbsentIsEmptyArray(t *testing.T) {
	for _, raw := range []string{"", "not json"} {
		d := refFixture(raw)
		b, _ := json.Marshal(map[string]any{"references": d.references})
		if string(b) != `{"references":[]}` {
			t.Errorf("%q: %s", raw, b)
		}
	}
}

func TestReferencesJSONShape(t *testing.T) {
	d := refFixture(refsJSON)
	b, _ := json.Marshal(d.references[0])
	var m map[string]any
	json.Unmarshal(b, &m)
	for _, k := range []string{"group", "title", "authors", "journal", "year", "pmid", "doi", "url", "note"} {
		if _, ok := m[k]; !ok {
			t.Errorf("missing %s in %s", k, b)
		}
	}
	if m["year"] != float64(2018) {
		t.Errorf("year: %v", m["year"])
	}
}

func TestTypeReferenceJoin(t *testing.T) {
	d := refFixture(refsJSON)
	row := func(ref string) map[string]any {
		r := map[string]any{"type": "x", "reference": ref}
		d.joinReference(r)
		return r
	}

	r := row("Smith et al. Cell 2018. PMID: 111")
	if r["reference_title"] != "Paper A" || r["reference_year"] != 2018 || r["reference_journal"] != "Cell" ||
		r["reference_authors"] != "A B" || r["reference_url"] != "https://pubmed.ncbi.nlm.nih.gov/111/" {
		t.Errorf("by pmid: %v", r)
	}
	r = row("see doi:10.1038/b.2).")
	if r["reference_title"] != "Paper B" || r["reference_url"] != "https://doi.org/10.1038/B.2" {
		t.Errorf("by doi (case-insensitive, trailing stripped): %v", r)
	}
	r = row("PMID 5555")
	if _, has := r["reference_title"]; has || r["reference_url"] != "https://pubmed.ncbi.nlm.nih.gov/5555/" {
		t.Errorf("bare pmid: %v", r)
	}
	r = row("https://doi.org/10.9999/zzz.")
	if r["reference_url"] != "https://doi.org/10.9999/zzz" || r["reference_title"] != nil {
		t.Errorf("bare doi: %v", r)
	}
	r = row("no identifiers here")
	if len(r) != 2 {
		t.Errorf("nothing added: %v", r)
	}
	if r = row("PMID:111"); r["reference"] != "PMID:111" {
		t.Errorf("reference text kept: %v", r)
	}
}
