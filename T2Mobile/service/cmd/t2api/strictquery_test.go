package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestStrictQuery(t *testing.T) {
	s := &server{}
	s.prepareList()
	h := s.routes()
	routes := []struct {
		path  string
		known []string // query strings that must NOT be 400
	}{
		{"/healthz", []string{""}},
		{"/statz", []string{""}},
		{"/v1/datasets", []string{""}},
		{"/v1/TCGA/meta", []string{"", "v=abc"}},
		{"/v1/TCGA/clinical", []string{"", "v=abc"}},
		{"/v1/TCGA/probes", []string{"", "v=abc", "q=CD&limit=5", "all=1&v=abc", "q=CD&limit=5&v=abc&all=1"}},
		{"/v1/TCGA/values", []string{"", "probes=A,B", "probe=A&probes=B", "v=abc&probes=A&fill=na", "probes=A&fill=zero&v=abc"}},
	}
	for _, rt := range routes {
		for _, q := range rt.known {
			u := rt.path
			if q != "" {
				u += "?" + q
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest("GET", u, nil))
			if rec.Code == 400 {
				t.Errorf("%s: known parameters refused: %s", u, rec.Body.String())
			}
		}
		junk := []string{"junk=1", "v=abc&junk=7", "junk", "%zz=1", "a=1;b=2", "&", "v=abc&&"}
		if strings.HasPrefix(rt.path, "/v1/TCGA/") {
			junk = append(junk, "probes=A&junk=1&fill=na")
		}
		if rt.path == "/v1/datasets" || strings.HasPrefix(rt.path, "/v1/TCGA/") && !strings.HasSuffix(rt.path, "/meta") {
			junk = append(junk, "usage=1")
		}
		for _, q := range junk {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest("GET", rt.path+"?"+q, nil))
			if rec.Code != 400 {
				t.Errorf("%s?%s: status %d, want 400", rt.path, q, rec.Code)
				continue
			}
			if rec.Header().Get("Cache-Control") != "no-store" {
				t.Errorf("%s?%s: Cache-Control %q", rt.path, q, rec.Header().Get("Cache-Control"))
			}
		}
	}
	// a repeated key is refused (one cache entry per spelling otherwise)
	for _, u := range []string{"/v1/TCGA/clinical?v=x&v=x", "/v1/TCGA/values?probes=A&probes=B", "/v1/TCGA/values?probe=A&probe=B", "/v1/TCGA/probes?q=a&q=b"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", u, nil))
		if rec.Code != 400 || !strings.Contains(rec.Body.String(), "repeated query parameter") || rec.Header().Get("Cache-Control") != "no-store" {
			t.Errorf("%s: %d %s", u, rec.Code, rec.Body.String())
		}
	}
	// v is refused where cacheable() is not called
	for _, p := range []string{"/healthz", "/statz", "/v1/datasets"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", p+"?v=abc", nil))
		if rec.Code != 400 {
			t.Errorf("%s?v=abc: %d", p, rec.Code)
		}
	}
	// the message names the parameter
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/v1/TCGA/clinical?v=abc&junk=1", nil))
	if rec.Code != 400 || !strings.Contains(rec.Body.String(), `"error":"unknown query parameter: junk"`) {
		t.Errorf("message: %d %s", rec.Code, rec.Body.String())
	}
}
