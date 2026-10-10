package main

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestLimited(t *testing.T) {
	s := &server{inflight: make(chan struct{}, 2)}
	release := make(chan struct{})
	slow := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			<-release
		}
		w.WriteHeader(200)
	})
	h := s.limited(slow)
	codes := make([]int, 4)
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ { // three slow requests, two tokens
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest("GET", "/v1/TCGA/values?probes=CD8A", nil))
			codes[i] = rec.Code
		}(i)
	}
	time.Sleep(100 * time.Millisecond)
	rec := httptest.NewRecorder() // the health check is never refused
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/healthz", nil))
	codes[3] = rec.Code
	close(release)
	wg.Wait()
	n503, n200 := 0, 0
	for _, c := range codes[:3] {
		if c == 503 {
			n503++
		} else if c == 200 {
			n200++
		}
	}
	if n200 != 2 || n503 != 1 || codes[3] != 200 {
		t.Errorf("codes %v: want two 200, one 503, healthz 200", codes)
	}
	if s.nBusy.Load() != 1 {
		t.Errorf("busy refusals %d, want 1", s.nBusy.Load())
	}
	// tokens are returned: a later request is answered
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/v1/TCGA/values?probes=CD8A", nil))
	if rec.Code != 200 {
		t.Errorf("after the burst: %d, want 200", rec.Code)
	}
}
