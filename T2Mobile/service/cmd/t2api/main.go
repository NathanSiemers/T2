// t2api: "gitr as a service".
//
// A read-only HTTP service over T2 dataset databases (tcga.db and friends). It answers the
// one question a client cannot answer for itself: the per-sample values of a set of probes.
// The contract is docs/API.md; the semantics are those of gitr() in the T2 R code and are
// checked against it by test_equivalence.R.
//
// Nothing here writes: databases are opened read-only and immutable, there is no state on
// disk, and the only mutable thing in memory is a bounded cache of encoded columns.
package main

import (
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"slices"
)

const (
	maxProbesPerRequest = 100
	// a request whose first names are ALL unknown is refused outright instead of answered
	// name by name: it is a mistake or a probe for weaknesses, not a use of the service
	unknownPrefix = 10
	maxProbeNameLen     = 200
	maxSearchLimit      = 200
)

type server struct {
	datasets map[string]*Dataset
	order    []string // dataset names, TCGA first
	started  time.Time
	nReq     atomic.Int64
	nErr     atomic.Int64
	stopOnce sync.Once
	contact      contactConfig
	contactLimit contactLimiter
}

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	tcga := flag.String("tcga", "/data/tcga.db", "the canonical TCGA database (served as dataset \"TCGA\"); empty to skip")
	dir := flag.String("datasets", "/data/datasets", "directory of additional <name>.db datasets; empty to skip")
	cacheMB := flag.Int("cache-mb", 512, "memory for cached probe columns, per dataset, in MB")
	conns := flag.Int("db-conns", 48, "database connections per dataset (concurrent uncached lookups)")
	memMB := flag.Int("mem-limit-mb", 3072, "soft memory limit for the Go runtime, in MB (keep below the container limit)")
	flag.Parse()
	dbConns = *conns
	debug.SetMemoryLimit(int64(*memMB) << 20)

	s := &server{datasets: map[string]*Dataset{}, started: time.Now()}
	s.contact = contactConfigFromEnv()
	if s.contact.dir != "" {
		log.Printf("contact form: messages are kept in %s", s.contact.dir)
	}
	// same discovery rule as discover_datasets() in dataset_registry.R
	add := func(name, path string) {
		t0 := time.Now()
		d, err := openDataset(name, path, int64(*cacheMB)<<20)
		if err != nil {
			log.Printf("dataset %s (%s): NOT loaded: %v", name, path, err)
			return
		}
		s.datasets[name] = d
		s.order = append(s.order, name)
		log.Printf("dataset %s: %d samples, %d clinical columns, %d probe names, loaded in %s",
			name, len(d.samples), len(d.clinOrder), len(d.probeNames), time.Since(t0).Round(time.Millisecond))
	}
	if *tcga != "" {
		if _, err := os.Stat(*tcga); err == nil {
			add("TCGA", *tcga)
		}
	}
	if *dir != "" {
		files, _ := filepath.Glob(filepath.Join(*dir, "*.db"))
		sort.Strings(files)
		for _, f := range files {
			name := strings.TrimSuffix(filepath.Base(f), ".db")
			if name != "TCGA" {
				add(name, f)
			}
		}
	}
	if len(s.datasets) == 0 {
		log.Fatal("no datasets could be loaded")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /statz", s.handleStats)
	mux.HandleFunc("GET /v1/datasets", s.handleDatasets)
	mux.HandleFunc("GET /v1/{ds}/meta", s.withDataset(s.handleMeta))
	mux.HandleFunc("GET /v1/{ds}/clinical", s.withDataset(s.handleClinical))
	mux.HandleFunc("GET /v1/{ds}/probes", s.withDataset(s.handleProbes))
	mux.HandleFunc("GET /v1/{ds}/values", s.withDataset(s.handleValues))
	mux.HandleFunc("POST /v1/contact", s.handleContact)

	srv := &http.Server{
		Addr:              *addr,
		Handler:           s.count(s.recovered(gzipped(mux))),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	log.Printf("t2api listening on %s, datasets: %s", *addr, strings.Join(s.order, ", "))
	log.Fatal(srv.ListenAndServe())
}

// ---------------------------------------------------------------------------------------
// middleware and helpers

func (s *server) count(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.nReq.Add(1)
		next.ServeHTTP(w, r)
	})
}

type gzipWriter struct {
	http.ResponseWriter
	gz *gzip.Writer
}

func (g *gzipWriter) Write(b []byte) (int, error) { return g.gz.Write(b) }

// gzipped compresses responses for clients that accept it. Columns of numbers compress about
// 3x; BestSpeed keeps the cost near a millisecond per response.
func gzipped(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Vary", "Accept-Encoding")
		gz, _ := gzip.NewWriterLevel(w, gzip.BestSpeed)
		defer gz.Close()
		next.ServeHTTP(&gzipWriter{ResponseWriter: w, gz: gz}, r)
	})
}

func (s *server) fail(w http.ResponseWriter, code int, msg string) {
	s.nErr.Add(1)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Del("ETag")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// withDataset resolves {ds} against the loaded datasets: the name is only ever used as a
// map key, never as a path or in SQL.
func (s *server) withDataset(h func(http.ResponseWriter, *http.Request, *Dataset)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		d := s.datasets[r.PathValue("ds")]
		if d == nil {
			s.fail(w, http.StatusNotFound, "unknown dataset")
			return
		}
		if !d.unchanged() { // see Dataset.unchanged: never answer from a replaced file
			s.fail(w, http.StatusServiceUnavailable, "dataset is being replaced, try again shortly")
			s.stopOnce.Do(func() {
				log.Printf("dataset %s: %s changed on disk; stopping so that it is loaded afresh", d.Name, d.Path)
				go func() { time.Sleep(300 * time.Millisecond); os.Exit(3) }()
			})
			return
		}
		h(w, r, d)
	}
}

// cacheable sets the caching headers and answers conditional requests; true = the request
// has been answered. etagKey distinguishes responses within a dataset; it is hashed, so the
// header has a fixed length and never carries bytes chosen by the client.
// A client that passes the dataset version it knows (?v=<version from /v1/datasets>) gets a
// response that may be kept for good: the URL then names one database build. If that version
// is no longer the one served, the answer is 409 and the client reloads /v1/datasets.
// Without ?v= the response must be revalidated (ETag, answered 304) before it is reused:
// that is how a client learns the current version, so it must never come from a cache
// unchecked (a cached /meta naming a version that is gone would make every ?v= request fail).
func (s *server) cacheable(w http.ResponseWriter, r *http.Request, d *Dataset, etagKey string) (done bool) {
	if v := r.URL.Query().Get("v"); v != "" {
		if v != d.version {
			s.fail(w, http.StatusConflict, "dataset version changed: reload /v1/datasets (current version "+d.version+")")
			return true
		}
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "no-cache")
	}
	sum := sha256.Sum256([]byte(etagKey))
	etag := `"` + d.version + "-" + hex.EncodeToString(sum[:12]) + `"`
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return true
	}
	return false
}

// recovered answers a panic in a handler with a plain 500 and keeps the process serving.
func (s *server) recovered(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if p := recover(); p != nil {
				log.Printf("panic serving %s: %v", r.URL.Path, p)
				s.fail(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// ---------------------------------------------------------------------------------------
// handlers

func (s *server) handleStats(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{
		"uptime_s": int(time.Since(s.started).Seconds()),
		"requests": s.nReq.Load(),
		"errors":   s.nErr.Load(),
	}
	ds := map[string]any{}
	for name, d := range s.datasets {
		ds[name] = d.cache.stats()
	}
	out["datasets"] = ds
	writeJSON(w, out)
}

func (s *server) handleDatasets(w http.ResponseWriter, r *http.Request) {
	type entry struct {
		Name     string            `json:"name"`
		Title    string            `json:"title"`
		Label    string            `json:"label"`
		Samples  int               `json:"n_samples"`
		Probes   int               `json:"n_probes"`
		Version  string            `json:"version"`
		Roles    Roles             `json:"roles"`
		Defaults map[string]string `json:"defaults"`
	}
	out := []entry{}
	for _, name := range s.order {
		d := s.datasets[name]
		out = append(out, entry{d.Name, d.Title, d.Label, len(d.samples), len(d.probeNames), d.version, d.Roles, d.Defaults})
	}
	w.Header().Set("Cache-Control", "no-cache") // the list of current versions: never reused unchecked
	writeJSON(w, map[string]any{"datasets": out})
}

func (s *server) handleMeta(w http.ResponseWriter, r *http.Request, d *Dataset) {
	if s.cacheable(w, r, d, "meta") {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(d.metaJSON)
}

func (s *server) handleClinical(w http.ResponseWriter, r *http.Request, d *Dataset) {
	if s.cacheable(w, r, d, "clinical") {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(d.clinicalJSON)
}

// handleProbes searches the selectable variable names (allprobes): case-insensitive, names
// that START with the query first, then names that contain it.
func (s *server) handleProbes(w http.ResponseWriter, r *http.Request, d *Dataset) {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	if len(q) > maxProbeNameLen {
		s.fail(w, http.StatusBadRequest, "query too long")
		return
	}
	limit := 50
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 {
		limit = min(v, maxSearchLimit)
	}
	// ranking: the exact name first, then names that start with the query, then names that
	// contain it; within a group the shorter name first, then alphabetical. So "T", "MET" or
	// "CD8B" are found however many names contain those letters (table order used to decide
	// which 60 of 500 matches were shown, and the exact match could be left out).
	var exact, starts, contains []string
	total := 0
	for i, low := range d.probeLower {
		idx := strings.Index(low, q)
		if idx < 0 {
			continue
		}
		total++
		switch {
		case low == q:
			exact = append(exact, d.probeNames[i])
		case idx == 0:
			starts = append(starts, d.probeNames[i])
		default:
			contains = append(contains, d.probeNames[i])
		}
	}
	byLength := func(a, b string) int {
		if len(a) != len(b) {
			return len(a) - len(b)
		}
		return strings.Compare(a, b)
	}
	slices.SortFunc(starts, byLength)
	slices.SortFunc(contains, byLength)
	res := append(append(exact, starts...), contains...)
	if len(res) > limit {
		res = res[:limit]
	}
	if res == nil {
		res = []string{}
	}
	w.Header().Set("Cache-Control", "public, max-age=86400")
	writeJSON(w, map[string]any{"dataset": d.Name, "query": q, "total_matches": total, "probes": res})
}

// handleValues is the gitr() of the API: the requested columns, aligned to the dataset's
// sample order (see /clinical). Names may be probes, clinical columns or the virtual
// `cohort` / `subtype`. Unknown names are listed in "missing", not an error.
func (s *server) handleValues(w http.ResponseWriter, r *http.Request, d *Dataset) {
	var names []string
	seen := map[string]bool{}
	q := r.URL.Query()
	for _, part := range append(q["probes"], q["probe"]...) {
		for _, n := range strings.Split(part, ",") {
			n = strings.TrimSpace(n)
			if n == "" || seen[n] {
				continue
			}
			if len(n) > maxProbeNameLen || strings.ContainsAny(n, "\x00\r\n") {
				s.fail(w, http.StatusBadRequest, "bad probe name")
				return
			}
			seen[n] = true
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		s.fail(w, http.StatusBadRequest, "no probes given (use ?probes=A,B,C)")
		return
	}
	if len(names) > maxProbesPerRequest {
		s.fail(w, http.StatusBadRequest, fmt.Sprintf("too many probes (max %d per request)", maxProbesPerRequest))
		return
	}
	// names are checked against the dataset's variable list first, in memory
	if len(names) >= unknownPrefix {
		anyKnown := false
		for _, n := range names[:unknownPrefix] {
			if d.isKnown(n) {
				anyKnown = true
				break
			}
		}
		if !anyKnown {
			s.fail(w, http.StatusBadRequest, fmt.Sprintf("none of the first %d names is a variable of this dataset", unknownPrefix))
			return
		}
	}
	if s.cacheable(w, r, d, "v-"+strings.Join(names, ",")) {
		return
	}
	cols := make([][]byte, 0, len(names))
	missing := []string{}
	for _, n := range names {
		c, err := d.column(n)
		if err != nil {
			log.Printf("%s: column %q: %v", d.Name, n, err)
			s.fail(w, http.StatusInternalServerError, "query failed")
			return
		}
		if c == nil {
			missing = append(missing, n)
			continue
		}
		cols = append(cols, c)
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"dataset":%s,"version":%s,"n":%d,"columns":[`, jsonString(d.Name), jsonString(d.version), len(d.samples))
	for i, c := range cols {
		if i > 0 {
			w.Write([]byte{','})
		}
		w.Write(c)
	}
	mj, _ := json.Marshal(missing)
	fmt.Fprintf(w, `],"missing":%s}`, mj)
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
