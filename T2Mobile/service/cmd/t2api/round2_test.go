package main

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

func gzReq() *http.Request {
	r := httptest.NewRequest("GET", "/x", nil)
	r.Header.Set("Accept-Encoding", "gzip")
	return r
}

func TestGzipPanicIs500(t *testing.T) {
	s := &server{}
	h := gzipped(s.recovered(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { panic("boom\nx") })))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, gzReq())
	if rec.Code != 500 {
		t.Fatalf("status %d", rec.Code)
	}
	var body io.Reader = rec.Body
	if rec.Header().Get("Content-Encoding") == "gzip" {
		zr, err := gzip.NewReader(rec.Body)
		if err != nil {
			t.Fatal(err)
		}
		body = zr
	}
	var m map[string]string
	if err := json.NewDecoder(body).Decode(&m); err != nil || m["error"] != "internal error" {
		t.Fatalf("body %v %v", m, err)
	}
}

func TestGzipPassThroughAndCompress(t *testing.T) {
	h := gzipped(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(304) }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, gzReq())
	if rec.Code != 304 || rec.Header().Get("Content-Encoding") != "" {
		t.Errorf("304: %d %q", rec.Code, rec.Header().Get("Content-Encoding"))
	}
	h = gzipped(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"a":1}`)) }))
	for i := 0; i < 3; i++ { // pooled writers are reused
		rec = httptest.NewRecorder()
		h.ServeHTTP(rec, gzReq())
		zr, err := gzip.NewReader(rec.Body)
		if err != nil || rec.Header().Get("Content-Encoding") != "gzip" {
			t.Fatalf("gzip: %v", err)
		}
		if b, _ := io.ReadAll(zr); string(b) != `{"a":1}` {
			t.Errorf("body %q", b)
		}
	}
	rec = httptest.NewRecorder()
	gzipped(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })).ServeHTTP(rec, gzReq())
	if rec.Code != 204 || rec.Header().Get("Content-Encoding") != "" {
		t.Errorf("204: %d", rec.Code)
	}
}

func searchFixture(n int) *Dataset {
	d := &Dataset{}
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("%s%d", []string{"TP", "MET", "gene", "CD", "a_TP53", "x"}[i%6], (i*7919)%1000)
		if i%97 == 0 {
			name = "tp53"
		}
		d.probeNames = append(d.probeNames, name)
		d.probeLower = append(d.probeLower, strings.ToLower(name))
	}
	return d
}

// the first implementation: collect everything, sort whole groups, cut
func oldSearch(d *Dataset, q string, limit int) ([]int, int) {
	var exact, starts, contains []int
	total := 0
	for i, low := range d.probeLower {
		idx := strings.Index(low, q)
		if idx < 0 {
			continue
		}
		total++
		switch {
		case low == q:
			exact = append(exact, i)
		case idx == 0:
			starts = append(starts, i)
		default:
			contains = append(contains, i)
		}
	}
	byLength := func(a, b int) int {
		x, y := d.probeNames[a], d.probeNames[b]
		if len(x) != len(y) {
			return len(x) - len(y)
		}
		return strings.Compare(x, y)
	}
	slices.SortStableFunc(starts, byLength)
	slices.SortStableFunc(contains, byLength)
	res := append(append(exact, starts...), contains...)
	if len(res) > limit {
		res = res[:limit]
	}
	return res, total
}

func TestSearchMatchesFullSort(t *testing.T) {
	d := searchFixture(1000)
	for _, q := range []string{"", "t", "tp", "tp53", "met", "met1", "gene", "_", "zzz", "53"} {
		for _, limit := range []int{1, 5, 50, 200, 5000} {
			// names (not indexes): equal names are interchangeable
			gi, gt := d.search(q, limit)
			wi, wt := oldSearch(d, q, limit)
			g, w := []string{}, []string{}
			for _, i := range gi {
				g = append(g, d.probeNames[i])
			}
			for _, i := range wi {
				w = append(w, d.probeNames[i])
			}
			if gt != wt || !reflect.DeepEqual(g, w) {
				t.Errorf("q=%q limit=%d: total %d/%d\n got %v\nwant %v", q, limit, gt, wt, g, w)
			}
		}
	}
}

func TestProbesSearchCaching(t *testing.T) {
	d := searchFixture(50)
	d.Name, d.version = "toy", "v1"
	d.typedTypes = []string{"probe"}
	d.typedSection, d.typedType, d.typedKind = make([]uint8, 50), make([]uint16, 50), make([]uint8, 50)
	s := &server{}
	do := func(url string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		s.handleProbes(rec, httptest.NewRequest("GET", url, nil), d)
		return rec
	}
	if cc := do("/?q=tp").Header().Get("Cache-Control"); cc != "no-cache" {
		t.Errorf("no v: %q", cc)
	}
	rec := do("/?q=tp&v=v1")
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "immutable") {
		t.Errorf("v: %q", cc)
	}
	if do("/?q=tp&v=old").Code != 409 {
		t.Errorf("stale v not refused")
	}
}

func TestFileVersion(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.db")
	hdr := make([]byte, 100)
	hdr[27] = 7
	os.WriteFile(p, hdr, 0o644)
	fi, _ := os.Stat(p)
	v1 := fileVersion(p, fi)
	hdr[27] = 8
	os.WriteFile(p, hdr, 0o644)
	if v2 := fileVersion(p, fi); v1 == v2 || !strings.HasSuffix(v1, "7") {
		t.Errorf("%s %s", v1, v2)
	}
	os.WriteFile(p, []byte("short"), 0o644) // no header: falls back
	fi, _ = os.Stat(p)
	if v := fileVersion(p, fi); v == "" {
		t.Error("empty")
	}
}

func TestOneLineStripsSeparatorsAndBidi(t *testing.T) {
	if got := oneLine("a b c‮d⁦e⁩f", 50); got != "abcdef" {
		t.Errorf("%q", got)
	}
}

func TestClientIPOrder(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.9:1"
	if a := clientIP(r); a != "10.0.0.9" {
		t.Errorf("remote %s", a)
	}
	r.Header.Set("X-Forwarded-For", "1.1.1.1, 2.2.2.2")
	if a := clientIP(r); a != "2.2.2.2" {
		t.Errorf("xff %s", a)
	}
	r.Header.Set("X-Real-IP", "3.3.3.3")
	if a := clientIP(r); a != "3.3.3.3" || clientAddr(r) != a {
		t.Errorf("real %s", a)
	}
}

func TestDatasetsListPrecomputed(t *testing.T) {
	a := &Dataset{Name: "a", Title: "A", version: "v1", Hidden: true, samples: []string{"s"}}
	b := &Dataset{Name: "b", Label: "B", version: "v2"}
	s := &server{datasets: map[string]*Dataset{"a": a, "b": b}, order: []string{"b", "a"}}
	old := []DatasetSummary{b.summary(), a.summary()}
	var want strings.Builder
	json.NewEncoder(&want).Encode(map[string]any{"datasets": old})
	rec := httptest.NewRecorder()
	s.handleDatasets(rec, httptest.NewRequest("GET", "/v1/datasets", nil))
	if rec.Body.String() != want.String() || !strings.Contains(rec.Body.String(), `"hidden":true`) {
		t.Errorf("body differs:\n%s\n%s", rec.Body.String(), want.String())
	}
	etag := rec.Header().Get("ETag")
	r := httptest.NewRequest("GET", "/v1/datasets", nil)
	r.Header.Set("If-None-Match", etag)
	rec = httptest.NewRecorder()
	s.handleDatasets(rec, r)
	if etag == "" || rec.Code != 304 {
		t.Errorf("etag %q code %d", etag, rec.Code)
	}
}

func TestContactBotCountsAgainstLimiter(t *testing.T) {
	s := &server{contact: contactConfig{dir: t.TempDir()}}
	post := func() int {
		r := httptest.NewRequest("POST", "/v1/contact", strings.NewReader(`{"website":"x","started":10}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-Real-IP", "9.9.9.9")
		rec := httptest.NewRecorder()
		s.handleContact(rec, r)
		return rec.Code
	}
	for i := 0; i < contactPerIP+3; i++ {
		if c := post(); c != 200 { // always ok: a bot learns nothing from the answer
			t.Fatalf("%d: %d", i, c)
		}
	}
	s.contactLimit.mu.Lock()
	n, total := s.contactLimit.byIP["9.9.9.9"], s.contactLimit.total
	s.contactLimit.mu.Unlock()
	if n != contactPerIP {
		t.Errorf("per-address budget: %d, want %d", n, contactPerIP)
	}
	if total != 0 {
		t.Errorf("bot hits must not use the shared daily quota: total %d", total)
	}
}
