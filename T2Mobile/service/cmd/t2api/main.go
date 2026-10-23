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
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	maxProbesPerRequest = 100
	// a request whose first names are ALL unknown is refused outright instead of answered
	// name by name: it is a mistake or a probe for weaknesses, not a use of the service
	unknownPrefix   = 10
	maxProbeNameLen = 200
	maxSearchLimit  = 200
)

type server struct {
	datasets     map[string]*Dataset
	order        []string // dataset names: dataset_meta `order` ascending, then alphabetical
	started      time.Time
	nReq         atomic.Int64
	nErr         atomic.Int64
	stopOnce     sync.Once
	contact      contactConfig
	contactLimit contactLimiter
	inflight     chan struct{} // one token per request being answered (-max-inflight)
	nBusy        atomic.Int64  // requests refused because every token was taken
	usage        *usageStats   // counts for /statz and the hourly line (usage.go); nil = off
	listOnce     sync.Once     // /v1/datasets answer, built once (prepareList)
	listJSON     []byte
	listETag     string
}

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	tcga := flag.String("tcga", "/data/tcga.db", "transitional: a TCGA database outside -datasets (served as \"TCGA\" unless datasets/TCGA.db exists); optional, ignored if absent")
	dir := flag.String("datasets", "/data/datasets", "directory of additional <name>.db datasets; empty to skip")
	cacheMB := flag.Int("cache-mb", 512, "memory for cached probe columns, per dataset, in MB")
	conns := flag.Int("db-conns", 48, "database connections per dataset (concurrent uncached lookups)")
	memMB := flag.Int("mem-limit-mb", 3072, "soft memory limit for the Go runtime, in MB (keep below the container limit)")
	inflight := flag.Int("max-inflight", 256, "requests answered at once; beyond it a request is refused at once with 503 (a flood then costs no memory and no disk time). 256 x a 100-probe answer is under 2 GB; a small standby takes 32")
	usageDir := flag.String("usage-dir", "", "when set, one JSON line of counts per hour is appended to <dir>/usage-YYYY-MM.jsonl (counts only; default off: the production container is read-only)")
	flag.Parse()
	dbConns = *conns
	debug.SetMemoryLimit(int64(*memMB) << 20)

	s := &server{datasets: map[string]*Dataset{}, started: time.Now(), inflight: make(chan struct{}, max(1, *inflight))}
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
	var files []string
	if *dir != "" {
		files, _ = filepath.Glob(filepath.Join(*dir, "*.db"))
	}
	if *tcga != "" {
		if _, err := os.Stat(*tcga); err != nil {
			log.Printf("-tcga %s not present: not used", *tcga)
			*tcga = ""
		}
	}
	for _, f := range datasetFiles(*tcga, files) {
		add(f.name, f.path)
	}
	s.order = orderDatasets(s.order, func(n string) (int, bool) {
		v, err := strconv.Atoi(strings.TrimSpace(s.datasets[n].meta["order"]))
		return v, err == nil
	})
	if len(s.datasets) == 0 {
		log.Fatal("no datasets could be loaded")
	}

	s.prepareList()
	s.usage = newUsage(s.order, time.Now)
	go s.usage.runHourly(*usageDir)

	mux := s.routes()

	srv := &http.Server{
		Addr:              *addr,
		Handler:           s.metered(s.count(s.limited(gzipped(s.recovered(mux))))),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	log.Printf("t2api listening on %s, datasets: %s", *addr, strings.Join(s.order, ", "))
	// graceful stop: SIGTERM (container stop) or SIGINT lets in-flight responses finish
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	select {
	case err := <-errc:
		log.Fatal(err)
	case <-ctx.Done():
	}
	log.Printf("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

// ---------------------------------------------------------------------------------------
// middleware and helpers

func (s *server) count(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.nReq.Add(1)
		next.ServeHTTP(w, r)
	})
}

// gzipWriter compresses a 2xx body lazily: Content-Encoding is set and the gzip writer is
// created on the first Write of such a body. A 304, an error status or an empty body is
// passed through plain.
type gzipWriter struct {
	http.ResponseWriter
	gz      *gzip.Writer
	code    int  // status waiting for the first Write (2xx only)
	pending bool // a 2xx status was given but not yet sent
	sent    bool // the status has gone to the client
}

var gzPool = sync.Pool{New: func() any {
	gz, _ := gzip.NewWriterLevel(io.Discard, gzip.BestSpeed)
	return gz
}}

func (g *gzipWriter) WriteHeader(code int) {
	if g.sent || g.pending {
		return
	}
	if code >= 200 && code < 300 && code != http.StatusNoContent {
		g.code, g.pending = code, true
		return
	}
	g.sent = true
	g.ResponseWriter.WriteHeader(code)
}

func (g *gzipWriter) Write(b []byte) (int, error) {
	if !g.sent && !g.pending {
		g.pending, g.code = true, http.StatusOK
	}
	if g.pending {
		h := g.Header()
		h.Set("Content-Encoding", "gzip")
		h.Del("Content-Length")
		g.pending, g.sent = false, true
		g.ResponseWriter.WriteHeader(g.code)
		g.gz = gzPool.Get().(*gzip.Writer)
		g.gz.Reset(g.ResponseWriter)
	}
	if g.gz == nil { // plain pass-through (error status)
		return g.ResponseWriter.Write(b)
	}
	return g.gz.Write(b)
}

func (g *gzipWriter) close() {
	if g.pending { // 2xx without a body
		g.pending, g.sent = false, true
		g.ResponseWriter.WriteHeader(g.code)
	}
	if g.gz != nil {
		g.gz.Close()
		g.gz.Reset(io.Discard)
		gzPool.Put(g.gz)
		g.gz = nil
	}
}

// gzipped compresses responses for clients that accept it. Columns of numbers compress about
// 3x; BestSpeed keeps the cost near a millisecond per response. It sits OUTSIDE recovered, so
// a 500 from a panic is written through it and never after a half-committed gzip stream.
func gzipped(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Add("Vary", "Accept-Encoding")
		g := &gzipWriter{ResponseWriter: w}
		defer g.close()
		next.ServeHTTP(g, r)
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

// routes builds the mux. Every GET route refuses a query parameter it does not read (see
// strictQuery); the contact form takes JSON only.
func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.strictQuery(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) }))
	mux.HandleFunc("GET /statz", s.strictQuery(s.handleStats))
	mux.HandleFunc("GET /v1/datasets", s.strictQuery(s.handleDatasets))
	mux.HandleFunc("GET /v1/{ds}/meta", s.strictQuery(s.withDataset(s.handleMeta), "v"))
	mux.HandleFunc("GET /v1/{ds}/clinical", s.strictQuery(s.withDataset(s.handleClinical), "v"))
	mux.HandleFunc("GET /v1/{ds}/probes", s.strictQuery(s.withDataset(s.handleProbes), "v", "q", "limit", "all"))
	mux.HandleFunc("GET /v1/{ds}/values", s.strictQuery(s.withDataset(s.handleValues), "v", "probes", "probe", "fill"))
	mux.HandleFunc("POST /v1/contact", s.handleContact)
	return mux
}

// strictQuery answers 400 (no-store, via fail) when the query holds a key the handler does
// not read. The Nginx cache key is the full request URI, and an ignored parameter would let
// a client store one cached copy of the same answer per junk value (?v=<ver>&junk=N is even
// immutable). `v` is honoured only where the handler calls cacheable(). The check runs
// before the dataset lookup, so it costs nothing and touches no database.
func (s *server) strictQuery(h http.HandlerFunc, allowed ...string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RawQuery != "" {
			// a malformed query (bad escape, ';', empty pieces such as "?&&") is dropped by the
			// parser but still varies the cache key, so it is refused too
			qv, err := url.ParseQuery(r.URL.RawQuery)
			if err != nil || slices.Contains(strings.Split(r.URL.RawQuery, "&"), "") {
				s.fail(w, http.StatusBadRequest, "malformed query string")
				return
			}
			for k, vs := range qv {
				if len(vs) > 1 && slices.Contains(allowed, k) {
					s.fail(w, http.StatusBadRequest, "repeated query parameter: "+clip(k))
					return
				}
			}
			var bad []string
			for k := range qv {
				if !slices.Contains(allowed, k) {
					bad = append(bad, k)
				}
			}
			if len(bad) > 0 {
				sort.Strings(bad)
				s.fail(w, http.StatusBadRequest, "unknown query parameter: "+clip(bad[0]))
				return
			}
		}
		h(w, r)
	}
}

func clip(k string) string {
	if len(k) > 40 {
		return k[:40] + "..."
	}
	return k
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

// limited bounds the requests answered at once. A request beyond the bound is refused at
// once with 503 and Retry-After (the app retries after a few seconds; Nginx counts it as a
// failure): a flood is turned away before it costs a database read or a response buffer.
// /healthz is exempt, so a watchdog still sees the process alive while it is busy.
func (s *server) limited(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		select {
		case s.inflight <- struct{}{}:
			defer func() { <-s.inflight }()
			next.ServeHTTP(w, r)
		default:
			s.nBusy.Add(1)
			if uw, ok := w.(*usageWriter); ok {
				uw.busy = true
			}
			s.nErr.Add(1)
			w.Header().Set("Retry-After", "3")
			w.Header().Set("Cache-Control", "no-store")
			http.Error(w, `{"error":"busy: try again in a few seconds"}`, http.StatusServiceUnavailable)
		}
	})
}

// recovered answers a panic in a handler with a plain 500 and keeps the process serving.
func (s *server) recovered(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if p := recover(); p != nil {
				log.Printf("panic serving %q: %v", r.URL.Path, p)
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
		"uptime_s":      int(time.Since(s.started).Seconds()),
		"requests":      s.nReq.Load(),
		"errors":        s.nErr.Load(),
		"busy_refusals": s.nBusy.Load(),
		"max_inflight":  cap(s.inflight),
	}
	ds := map[string]any{}
	for name, d := range s.datasets {
		ds[name] = d.cache.stats()
	}
	out["datasets"] = ds
	if s.usage != nil {
		out["usage"] = s.usage.snapshot()
	}
	writeJSON(w, out)
}

// prepareList builds the /v1/datasets answer once (datasets never change while served: a
// changed file stops the process). The ETag is a hash of the bytes, which carry every version.
func (s *server) prepareList() {
	s.listOnce.Do(func() {
		out := []DatasetSummary{}
		for _, name := range s.order {
			out = append(out, s.datasets[name].summary())
		}
		var buf bytes.Buffer
		json.NewEncoder(&buf).Encode(map[string]any{"datasets": out})
		s.listJSON = buf.Bytes()
		sum := sha256.Sum256(s.listJSON)
		s.listETag = `"` + hex.EncodeToString(sum[:12]) + `"`
	})
}

func (s *server) handleDatasets(w http.ResponseWriter, r *http.Request) {
	s.prepareList()
	w.Header().Set("Cache-Control", "no-cache") // the list of current versions: never reused unchecked
	w.Header().Set("ETag", s.listETag)
	if r.Header.Get("If-None-Match") == s.listETag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(s.listJSON)
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
	// ?all=1: the whole list (about 1.5 MB for TCGA, 300 KB gzipped), cacheable by version
	if r.URL.Query().Get("all") == "1" {
		if s.cacheable(w, r, d, "probes-all") {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(d.probesJSON)
		return
	}
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	if len(q) > maxProbeNameLen {
		s.fail(w, http.StatusBadRequest, "query too long")
		return
	}
	limit := 50
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 {
		limit = min(v, maxSearchLimit)
	}
	// same caching rules as the other endpoints: long with a matching ?v=, else revalidate
	if s.cacheable(w, r, d, "probes-q="+strconv.Itoa(limit)+"|"+q) {
		return
	}
	res, total := d.search(q, limit)
	names := make([]string, len(res))
	for i, ix := range res {
		names[i] = d.probeNames[ix]
	}
	out := map[string]any{"dataset": d.Name, "query": q, "total_matches": total, "probes": names,
		"hits_typed": d.typedHits(res)}
	writeJSON(w, out)
}

// search ranks the names matching q: the exact name first, then names that start with the
// query, then names that contain it; within a group the shorter name first, then alphabetical.
// So "T", "MET" or "CD8B" are found however many names contain those letters (table order
// used to decide which 60 of 500 matches were shown, and the exact match could be left out).
// Only the best `limit` of each group are kept while scanning: O(n + limit log limit) time and
// O(limit) memory however many names match. total counts every match.
func (d *Dataset) search(q string, limit int) (res []int, total int) {
	less := func(a, b int) bool {
		x, y := d.probeNames[a], d.probeNames[b]
		if len(x) != len(y) {
			return len(x) < len(y)
		}
		return x < y
	}
	keep := func(buf []int, i int) []int { // insert i into the sorted buf, at most limit long
		if len(buf) == limit && !less(i, buf[limit-1]) {
			return buf
		}
		pos := sort.Search(len(buf), func(k int) bool { return less(i, buf[k]) })
		if len(buf) < limit {
			buf = append(buf, 0)
		}
		copy(buf[pos+1:], buf[pos:])
		buf[pos] = i
		return buf
	}
	var exact, starts, contains []int
	for i, low := range d.probeLower {
		idx := strings.Index(low, q)
		if idx < 0 {
			continue
		}
		total++
		switch {
		case low == q:
			if len(exact) < limit {
				exact = append(exact, i)
			}
		case idx == 0:
			starts = keep(starts, i)
		default:
			contains = keep(contains, i)
		}
	}
	res = append(append(exact, starts...), contains...)
	if len(res) > limit {
		res = res[:limit]
	}
	return res, total
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
			// stop as soon as the cap is passed, so a request listing thousands of names
			// (within the header limit) never builds a large list before being refused
			if len(names) > maxProbesPerRequest {
				s.fail(w, http.StatusBadRequest, fmt.Sprintf("too many probes (max %d per request)", maxProbesPerRequest))
				return
			}
		}
	}
	if len(names) == 0 {
		s.fail(w, http.StatusBadRequest, "no probes given (use ?probes=A,B,C)")
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
	// fill: how a sample tested for a probe's type but without a stored value is served (see
	// fetchProbe). The key of the na answer is unchanged, so existing clients see no difference.
	fill := strings.ToLower(strings.TrimSpace(q.Get("fill")))
	if fill == "" {
		fill = "na"
	}
	if fill != "na" && fill != "zero" && fill != "floor" {
		s.fail(w, http.StatusBadRequest, "fill must be na, zero or floor")
		return
	}
	etagKey := "v-" + strings.Join(names, ",")
	if fill != "na" {
		etagKey += "|fill=" + fill
	}
	if s.cacheable(w, r, d, etagKey) {
		return
	}
	cols := make([][]byte, 0, len(names))
	missing := []string{}
	offered := map[string]bool{"na": true}
	applied := false
	filled, testedN := map[string]int{}, map[string]int{}
	for _, n := range names {
		c, aux, err := d.columnFill(n, fill)
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
		if aux.typ != "" {
			for _, f := range d.fillOptionsOf(aux.typ) {
				offered[f] = true
			}
			if fill != "na" && d.fillOffers(aux.typ, fill) {
				applied = true
				if aux.filled > 0 {
					filled[n], testedN[n] = aux.filled, aux.testedN
				}
			}
		}
	}
	if fill != "na" && !applied {
		s.fail(w, http.StatusBadRequest, "fill not available for these variables")
		return
	}
	opts := []string{}
	for _, f := range fillOrder {
		if offered[f] {
			opts = append(opts, f)
		}
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
	oj, _ := json.Marshal(opts)
	fmt.Fprintf(w, `],"missing":%s,"fill_options":%s`, mj, oj)
	if fill != "na" {
		fj, _ := json.Marshal(filled) // maps marshal with sorted keys
		tj, _ := json.Marshal(testedN)
		fmt.Fprintf(w, `,"fill":%s,"filled":%s,"tested_n":%s`, jsonString(fill), fj, tj)
	}
	w.Write([]byte{'}'})
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

type datasetFile struct{ name, path string }

// datasetFiles: every *.db in the datasets directory is a dataset named by its file name
// without .db. The -tcga file (transitional) is added as "TCGA" unless datasets/TCGA.db exists.
func datasetFiles(tcga string, files []string) []datasetFile {
	sort.Strings(files)
	var out []datasetFile
	have := map[string]bool{}
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), ".db")
		have[name] = true
		out = append(out, datasetFile{name, f})
	}
	if tcga != "" {
		if have["TCGA"] {
			log.Printf("both -tcga %s and datasets/TCGA.db exist: serving the datasets one", tcga)
		} else {
			out = append([]datasetFile{{"TCGA", tcga}}, out...)
		}
	}
	return out
}

// orderDatasets: by the integer `order` of dataset_meta (ascending; a dataset without one
// comes after all that have one), then by name.
func orderDatasets(names []string, order func(string) (int, bool)) []string {
	out := append([]string{}, names...)
	slices.SortStableFunc(out, func(a, b string) int {
		va, oa := order(a)
		vb, ob := order(b)
		switch {
		case oa && ob && va != vb:
			return va - vb
		case oa != ob:
			if oa {
				return -1
			}
			return 1
		}
		return strings.Compare(a, b)
	})
	return out
}
