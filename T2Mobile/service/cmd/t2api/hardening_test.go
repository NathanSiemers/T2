package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// value variants of the query: each distinct answer has one canonical, cacheable spelling
func TestQueryValueRules(t *testing.T) {
	f := t.TempDir() + "/x.db"
	os.WriteFile(f, []byte("x"), 0o600)
	fi, _ := os.Stat(f)
	d := &Dataset{Name: "TCGA", Path: f, version: "v1", fileSize: fi.Size(), fileMtime: fi.ModTime(), fileIno: inode(fi),
		known: map[string]struct{}{}, clin: map[string][]byte{}, cache: newColumnCache(1 << 20)}
	s := &server{datasets: map[string]*Dataset{"TCGA": d}, order: []string{"TCGA"}}
	s.prepareList()
	h := s.routes()
	bad := []string{
		"/v1/TCGA/probes?all=2", "/v1/TCGA/probes?all=x", "/v1/TCGA/probes?all=", "/v1/TCGA/probes?all=01",
		"/v1/TCGA/probes?q=a&limit=abc", "/v1/TCGA/probes?q=a&limit=0", "/v1/TCGA/probes?q=a&limit=-3",
		"/v1/TCGA/probes?q=a&limit=", "/v1/TCGA/probes?q=a&limit=5.5", "/v1/TCGA/probes?q=a&limit=%205",
		"/v1/TCGA/values?probes=A&fill=NA", "/v1/TCGA/values?probes=A&fill=Zero", "/v1/TCGA/values?probes=A&fill=",
		"/v1/TCGA/values?probes=A&fill=%20na", "/v1/TCGA/values?probes=A&fill=ones",
		"/v1/TCGA/values?probes=A,,B", "/v1/TCGA/values?probes=A,", "/v1/TCGA/values?probes=,A",
		"/v1/TCGA/values?probes=A,%20B", "/v1/TCGA/values?probes=%20A", "/v1/TCGA/values?probe=A%20&probes=B",
	}
	good := map[string]string{
		"/v1/TCGA/probes?all=1&v=v1":              "public, max-age=31536000, immutable",
		"/v1/TCGA/probes?q=cd8&limit=5&v=v1":      "public, max-age=31536000, immutable",
		"/v1/TCGA/probes?q=cd8&limit=99999&v=v1":  "public, max-age=300", // clamped: not canonical
		"/v1/TCGA/probes?q=CD8&v=v1":              "public, max-age=300", // upper case: not canonical
		"/v1/TCGA/values?probes=A,B&fill=na&v=v1": "public, max-age=31536000, immutable",
		"/v1/TCGA/values?probes=A,B,A&v=v1":       "public, max-age=300", // duplicate: not canonical
		"/v1/TCGA/values?probe=A&probes=B&v=v1":   "public, max-age=31536000, immutable",
		"/v1/TCGA/probes?q=cd8&limit=5":           "no-cache",
	}
	for u, want := range good {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", u, nil))
		if rec.Code != 200 || rec.Header().Get("Cache-Control") != want {
			t.Errorf("%s: %d %q, want 200 %q (%s)", u, rec.Code, rec.Header().Get("Cache-Control"), want, rec.Body.String())
		}
	}
	for _, u := range bad {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", u, nil))
		if rec.Code != 400 || rec.Header().Get("Cache-Control") != "no-store" {
			t.Errorf("%s: %d %q, want 400 no-store", u, rec.Code, rec.Header().Get("Cache-Control"))
		}
		if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s: no nosniff", u)
		}
	}
}

func TestCanonicalCacheHeader(t *testing.T) {
	d := &Dataset{Name: "T", version: "v1"}
	s := &server{}
	for _, c := range []struct {
		canonical bool
		want      string
	}{{true, "public, max-age=31536000, immutable"}, {false, "public, max-age=300"}} {
		rec := httptest.NewRecorder()
		done := s.cacheable(rec, httptest.NewRequest("GET", "/x?v=v1", nil), d, "k", c.canonical)
		if done || rec.Header().Get("Cache-Control") != c.want {
			t.Errorf("canonical=%v: %q", c.canonical, rec.Header().Get("Cache-Control"))
		}
	}
	rec := httptest.NewRecorder()
	s.cacheable(rec, httptest.NewRequest("GET", "/x", nil), d, "k", false)
	if rec.Header().Get("Cache-Control") != "no-cache" {
		t.Errorf("no v: %q", rec.Header().Get("Cache-Control"))
	}
}

func TestNosniffOnFailAndJSON(t *testing.T) {
	s := &server{}
	rec := httptest.NewRecorder()
	s.fail(rec, 400, "x")
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Error("fail: no nosniff")
	}
	rec = httptest.NewRecorder()
	writeJSON(rec, map[string]int{"a": 1})
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Error("writeJSON: no nosniff")
	}
}

func contactReq(ct, body string) *http.Request {
	r := httptest.NewRequest("POST", "/v1/contact", strings.NewReader(body))
	if ct != "" {
		r.Header.Set("Content-Type", ct)
	}
	return r
}

func TestContactParsing(t *testing.T) {
	good := `{"name":"A","email":"a@b.org","message":"hi","started":10}`
	s := &server{contact: contactConfig{dir: t.TempDir()}}
	h := s.routes()
	cases := []struct {
		name, ct, body string
		want           int
	}{
		{"ok", "application/json", good, 200},
		{"ok charset", "application/json; charset=utf-8", good, 200},
		{"jsonx", "application/jsonx", good, 415},
		{"text", "text/plain", good, 415},
		{"none", "", good, 415},
		{"trailing object", "application/json", good + `{"x":1}`, 400},
		{"trailing junk", "application/json", good + " garbage", 400},
		{"trailing space ok", "application/json", good + " \n", 200},
		{"double dot domain", "application/json", `{"name":"A","email":"a@b..cc","message":"hi","started":10}`, 400},
		{"no tld", "application/json", `{"name":"A","email":"a@b","message":"hi","started":10}`, 400},
		{"display name", "application/json", `{"name":"A","email":"X <a@b.org>","message":"hi","started":10}`, 400},
		{"unknown field", "application/json", `{"name":"A","email":"a@b.org","message":"hi","started":10,"z":1}`, 400},
	}
	for i, c := range cases {
		rec := httptest.NewRecorder()
		r := contactReq(c.ct, c.body)
		r.RemoteAddr = net.JoinHostPort("10.9.0."+string(rune('1'+i%9)), "1") // spread over addresses: this is not the limiter test
		h.ServeHTTP(rec, r)
		if rec.Code != c.want {
			t.Errorf("%s: %d, want %d (%s)", c.name, rec.Code, c.want, rec.Body.String())
		}
	}
}

func TestClientIPTrust(t *testing.T) {
	old := trustedProxies
	defer func() { trustedProxies = old }()
	mk := func(peer string, hdr map[string]string) *http.Request {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = peer
		for k, v := range hdr {
			r.Header.Set(k, v)
		}
		return r
	}
	trustedProxies = nil
	if got := clientIP(mk("203.0.113.9:5555", map[string]string{"X-Real-IP": "1.2.3.4", "X-Forwarded-For": "5.6.7.8"})); got != "203.0.113.9" {
		t.Errorf("no trusted proxies: %q", got)
	}
	var err error
	trustedProxies, err = parseTrustedProxies("172.18.0.0/16, 10.0.0.0/8")
	if err != nil || len(trustedProxies) != 2 {
		t.Fatalf("parse: %v %v", trustedProxies, err)
	}
	if _, err := parseTrustedProxies("nonsense"); err == nil {
		t.Error("bad CIDR accepted")
	}
	cases := []struct {
		name string
		r    *http.Request
		want string
	}{
		{"trusted real-ip", mk("172.18.0.5:1", map[string]string{"X-Real-IP": "1.2.3.4"}), "1.2.3.4"},
		{"trusted xff last", mk("172.18.0.5:1", map[string]string{"X-Forwarded-For": "9.9.9.9, 1.2.3.4"}), "1.2.3.4"},
		{"trusted v6 real-ip", mk("172.18.0.5:1", map[string]string{"X-Real-IP": "2001:db8::1"}), "2001:db8::1"},
		{"trusted no headers", mk("172.18.0.5:1", nil), "172.18.0.5"},
		{"untrusted peer spoof", mk("203.0.113.9:1", map[string]string{"X-Real-IP": "1.2.3.4"}), "203.0.113.9"},
		{"trusted unparseable", mk("172.18.0.5:1", map[string]string{"X-Real-IP": "not-an-ip"}), "172.18.0.5"},
		{"trusted over-long", mk("172.18.0.5:1", map[string]string{"X-Real-IP": strings.Repeat("1", 46)}), "172.18.0.5"},
		{"trusted bad real falls to xff", mk("172.18.0.5:1", map[string]string{"X-Real-IP": "x", "X-Forwarded-For": "1.2.3.4"}), "1.2.3.4"},
		{"trusted with port", mk("172.18.0.5:1", map[string]string{"X-Real-IP": "1.2.3.4:80"}), "172.18.0.5"},
	}
	for _, c := range cases {
		if got := clientIP(c.r); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

// a spoofed X-Real-IP must not move a client into a fresh contact bucket
func TestContactLimitNotBypassedBySpoof(t *testing.T) {
	old := trustedProxies
	trustedProxies = nil
	defer func() { trustedProxies = old }()
	s := &server{contact: contactConfig{dir: t.TempDir()}}
	h := s.routes()
	body := `{"name":"A","email":"a@b.org","message":"hi","started":10}`
	var last int
	for i := 0; i < contactPerIP+1; i++ {
		r := contactReq("application/json", body)
		r.RemoteAddr = "203.0.113.9:4000"
		r.Header.Set("X-Real-IP", "198.51.100."+string(rune('1'+i)))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		last = rec.Code
	}
	if last != 429 {
		t.Errorf("request %d: %d, want 429", contactPerIP+1, last)
	}
}

// one budget for all datasets: two datasets sharing a cache never exceed it together
func TestSharedCacheBudget(t *testing.T) {
	c := newColumnCache(10 << 10)
	a := &Dataset{Name: "A", cache: c}
	b := &Dataset{Name: "B", cache: c}
	blob := func() ([]byte, colAux, error) { return make([]byte, 1000), colAux{}, nil }
	for i := 0; i < 20; i++ {
		for _, d := range []*Dataset{a, b} {
			if _, _, err := d.cache.get(d.Name+"\x00p"+string(rune('a'+i)), blob); err != nil {
				t.Fatal(err)
			}
		}
	}
	st := c.stats()
	if st["bytes"] > st["budget_bytes"] || st["evicted"] == 0 {
		t.Errorf("shared cache: %v", st)
	}
	// the same probe name in two datasets is two entries
	c2 := newColumnCache(1 << 20)
	n := 0
	for _, ds := range []string{"A", "B"} {
		c2.get(ds+"\x00CD8A", func() ([]byte, colAux, error) { n++; return []byte("x"), colAux{}, nil })
	}
	if n != 2 {
		t.Errorf("keys collide across datasets: %d loads", n)
	}
}

// trustTestPeers: the peers these tests use (httptest's 192.0.2.1 and 10.0.0.x) act as the proxy
func trustTestPeers(t *testing.T) {
	old := trustedProxies
	n, err := parseTrustedProxies("192.0.2.0/24,10.0.0.0/8")
	if err != nil {
		t.Fatal(err)
	}
	trustedProxies = n
	t.Cleanup(func() { trustedProxies = old })
}
