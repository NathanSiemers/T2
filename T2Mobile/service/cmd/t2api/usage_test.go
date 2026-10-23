package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func TestMetaTrue(t *testing.T) {
	for v, want := range map[string]bool{"1": true, "true": true, "YES": true, " Yes ": true, "0": false, "": false, "no": false, "2": false} {
		if metaTrue(v) != want {
			t.Errorf("metaTrue(%q) = %v", v, !want)
		}
	}
	d := &Dataset{Name: "demo", Label: "Demo", meta: map[string]string{"hidden": "1"}}
	d.Hidden = metaTrue(d.meta["hidden"])
	b, _ := json.Marshal(d.summary())
	if !strings.Contains(string(b), `"hidden":true`) {
		t.Errorf("hidden dataset: %s", b)
	}
	e := &Dataset{Name: "real", Label: "Real", meta: map[string]string{}}
	b, _ = json.Marshal(e.summary())
	if !strings.Contains(string(b), `"hidden":false`) {
		t.Errorf("dataset without the key: %s", b)
	}
}

func TestClassify(t *testing.T) {
	u := newUsage([]string{"TCGA", "CPTAC"}, time.Now)
	cases := []struct{ method, path, q, ep, ds string }{
		{"GET", "/healthz", "", "healthz", ""},
		{"GET", "/statz", "", "statz", ""},
		{"GET", "/v1/datasets", "", "datasets", ""},
		{"POST", "/v1/contact", "", "contact", ""},
		{"GET", "/v1/TCGA/meta", "", "meta", "TCGA"},
		{"GET", "/v1/CPTAC/clinical", "v=x", "clinical", "CPTAC"},
		{"GET", "/v1/TCGA/probes", "all=1&v=3", "probes_all", "TCGA"},
		{"GET", "/v1/TCGA/probes", "q=CD8A", "probes_search", "TCGA"},
		{"GET", "/v1/TCGA/values", "probes=TP53", "values", "TCGA"},
		{"GET", "/v1/NOPE/values", "probes=TP53", "values", "other"},
		{"GET", "/v1/TCGA/secret", "", "other", "TCGA"},
		{"GET", "/v1/TCGA", "", "other", ""},
		{"GET", "/wp-login.php", "", "other", ""},
	}
	for _, c := range cases {
		ep, ds := u.classify(c.method, c.path, c.q)
		if ep != c.ep || ds != c.ds {
			t.Errorf("%s %s?%s: got %s/%s want %s/%s", c.method, c.path, c.q, ep, ds, c.ep, c.ds)
		}
	}
}

func TestClientKindAndStatus(t *testing.T) {
	for ua, want := range map[string]string{"T2 iOS/1.0 (3)": "ios", "T2-shiny/2": "web", "curl/8": "other", "": "other", "Mozilla T2 iOS": "other"} {
		if got := clientKind(ua); got != want {
			t.Errorf("UA %q: %s want %s", ua, got, want)
		}
	}
	for code, want := range map[int]string{200: "2xx", 204: "2xx", 304: "304", 400: "4xx", 404: "4xx", 409: "4xx", 429: "429", 500: "5xx", 502: "5xx", 503: "503"} {
		if got := statusClass(code); got != want {
			t.Errorf("status %d: %s want %s", code, got, want)
		}
	}
	for d, want := range map[time.Duration]int{5 * time.Millisecond: 0, 10 * time.Millisecond: 0, 11 * time.Millisecond: 1, 200 * time.Millisecond: 2, time.Second: 3, 1001 * time.Millisecond: 4} {
		if got := latencyBucket(d); got != want {
			t.Errorf("latency %v: %d want %d", d, got, want)
		}
	}
}

func TestClientAddr(t *testing.T) {
	trustTestPeers(t)
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.9:5555"
	if a := clientAddr(r); a != "10.0.0.9" {
		t.Errorf("remote: %s", a)
	}
	r.Header.Set("X-Forwarded-For", "203.0.113.5, 10.0.0.1")
	if a := clientAddr(r); a != "10.0.0.1" { // the LAST element: the proxy's word
		t.Errorf("xff: %s", a)
	}
	r.Header.Set("X-Real-IP", "198.51.100.7")
	if a := clientAddr(r); a != "198.51.100.7" {
		t.Errorf("real-ip: %s", a)
	}
}

// the middleware end to end: statuses, bytes, busy refusals, per-minute client numbers, ring
// rollover, and that no address reaches the JSON.
func TestUsageMiddlewareAndRing(t *testing.T) {
	trustTestPeers(t)
	clk := &fakeClock{time.Date(2026, 10, 21, 1, 59, 30, 0, time.UTC)}
	s := &server{inflight: make(chan struct{}, 1)}
	s.usage = newUsage([]string{"TCGA"}, clk.now)
	release := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/{ds}/values", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("slow") != "" {
			<-release
		}
		w.Write([]byte("0123456789"))
	})
	h := s.metered(s.limited(mux))
	do := func(path, ip, ua string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("X-Real-IP", ip)
		req.Header.Set("User-Agent", ua)
		h.ServeHTTP(rec, req)
		return rec
	}
	do("/v1/TCGA/values?probes=SECRETPROBE", "192.0.2.1", "T2 iOS/1.0")
	do("/v1/TCGA/values?probes=SECRETPROBE", "192.0.2.1", "T2 iOS/1.0")
	do("/v1/TCGA/values?probes=SECRETPROBE", "192.0.2.2", "T2-shiny/1")
	do("/v1/TCGA/nothing", "192.0.2.3", "curl/8")
	// a busy refusal: one slow request holds the only token
	done := make(chan bool)
	go func() { do("/v1/TCGA/values?slow=1", "192.0.2.4", "x"); done <- true }()
	time.Sleep(100 * time.Millisecond)
	if rec := do("/v1/TCGA/values?probes=A", "192.0.2.5", "x"); rec.Code != 503 {
		t.Fatalf("expected a busy refusal, got %d", rec.Code)
	}
	close(release)
	<-done

	v := s.usage.snapshot()
	last := v.Minutes[59]
	if last.Requests != 6 || last.ByEndpoint["values"] != 5 || last.ByEndpoint["other"] != 1 {
		t.Errorf("endpoints: %+v", last.counts)
	}
	if last.ByDataset["TCGA"] != 6 || last.ByStatus["2xx"] != 4 || last.ByStatus["4xx"] != 1 || last.ByStatus["503"] != 1 {
		t.Errorf("dataset/status: %+v", last.counts)
	}
	if last.ByClient["ios"] != 2 || last.ByClient["web"] != 1 || last.ByClient["other"] != 3 {
		t.Errorf("clients: %+v", last.ByClient)
	}
	if last.Busy != 1 || s.usage.snapshot().Today.Busy != 1 {
		t.Errorf("busy: %d", last.Busy)
	}
	if last.Bytes < 40 { // four 10-byte answers, plus the error bodies
		t.Errorf("bytes %d < 40", last.Bytes)
	}
	if last.Distinct != 5 || last.MaxOne != 2 {
		t.Errorf("distinct %d (want 5), max per client %d (want 2)", last.Distinct, last.MaxOne)
	}
	if v.Today.Requests != 6 || len(v.Days) != 1 {
		t.Errorf("today: %+v days %d", v.Today.counts, len(v.Days))
	}

	// privacy: marshal /statz-like output and look for addresses and probe names
	b, _ := json.Marshal(map[string]any{"usage": v})
	for _, bad := range []string{"192.0.2", "SECRETPROBE", "curl"} {
		if strings.Contains(string(b), bad) {
			t.Errorf("usage JSON contains %q", bad)
		}
	}

	// rollover: a minute later the per-minute client numbers start again; the old slot stays
	clk.t = clk.t.Add(time.Minute)
	do("/v1/TCGA/values?probes=A", "192.0.2.1", "T2 iOS/1.0")
	v = s.usage.snapshot()
	if v.Minutes[59].Requests != 1 || v.Minutes[59].Distinct != 1 || v.Minutes[59].MaxOne != 1 {
		t.Errorf("new minute: %+v", v.Minutes[59])
	}
	if v.Minutes[58].Requests != 6 || v.Minutes[58].Distinct != 5 {
		t.Errorf("previous minute: %+v", v.Minutes[58])
	}
	if len(s.usage.clients) != 1 {
		t.Errorf("address map not dropped at the minute's end: %d entries", len(s.usage.clients))
	}
	// day change: a second day total
	clk.t = clk.t.Add(22 * time.Hour) // past midnight
	do("/v1/TCGA/values?probes=A", "192.0.2.1", "T2 iOS/1.0")
	v = s.usage.snapshot()
	if len(v.Days) != 2 || v.Today.Requests != 1 || v.Days[0].Requests != 7 || v.Days[0].Date != "2026-10-21" {
		t.Errorf("days: %+v today %+v", v.Days, v.Today.counts)
	}
	// 24 h later the first slot has been overwritten (ring of 1440 minutes)
	clk.t = time.Date(2026, 10, 22, 1, 59, 30, 0, time.UTC) // exactly 1440 minutes after the first request
	do("/v1/TCGA/values?probes=A", "192.0.2.1", "T2 iOS/1.0")
	if h := s.usage.hour(time.Date(2026, 10, 21, 1, 0, 0, 0, time.UTC)); h.Requests != 0 {
		t.Errorf("an hour older than 24 h should be gone, has %d requests", h.Requests)
	}
}

func TestHourlyLineAndFile(t *testing.T) {
	clk := &fakeClock{time.Date(2026, 10, 21, 1, 10, 0, 0, time.UTC)}
	u := newUsage([]string{"TCGA"}, clk.now)
	for i := 0; i < 3; i++ {
		u.record("values", "TCGA", "2xx", "ios", "192.0.2.1", 0, 100, false)
	}
	u.record("values", "TCGA", "429", "web", "192.0.2.2", 4, 10, false)
	clk.t = clk.t.Add(20 * time.Minute)
	u.record("meta", "TCGA", "503", "other", "192.0.2.3", 2, 10, true)
	h := u.hour(time.Date(2026, 10, 21, 1, 0, 0, 0, time.UTC))
	want := "usage 2026-10-21T01:00Z requests=5 ios=3 web=1 other=1 values=4 429=1 503=1 busy=1 " +
		"p_latency: ≤10ms=60% ≤50ms=0% ≤200ms=20% ≤1s=0% >1s=20% distinct_clients_max=2 max_per_client=3"
	if got := h.line(); got != want {
		t.Errorf("line:\n got %s\nwant %s", got, want)
	}
	for _, bad := range []string{"192.0.2"} {
		if strings.Contains(h.line(), bad) {
			t.Errorf("line contains %q", bad)
		}
	}
	dir := t.TempDir()
	u.emitHour(time.Date(2026, 10, 21, 1, 0, 0, 0, time.UTC), dir)
	u.emitHour(time.Date(2026, 10, 21, 1, 0, 0, 0, time.UTC), dir)
	b, err := os.ReadFile(filepath.Join(dir, "usage-2026-10.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	var rec map[string]any
	if len(lines) != 2 || json.Unmarshal([]byte(lines[0]), &rec) != nil || rec["requests"].(float64) != 5 || rec["max_per_client"].(float64) != 3 {
		t.Errorf("jsonl: %q", b)
	}
	if strings.Contains(string(b), "192.0.2") {
		t.Errorf("jsonl contains an address")
	}
	if st, _ := os.Stat(filepath.Join(dir, "usage-2026-10.jsonl")); st.Mode().Perm()&0o007 != 0 {
		t.Errorf("mode %v", st.Mode())
	}
	// a directory that cannot be written: logged, not fatal
	u.emitHour(time.Date(2026, 10, 21, 1, 0, 0, 0, time.UTC), filepath.Join(dir, "missing", "x"))
}
