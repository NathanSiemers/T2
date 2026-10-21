package main

// Usage metrics: counts only, in memory, for the operator's eyes (/statz, internal) and one
// log line per hour. Privacy: nothing here records an address, a probe name, a query or a
// selection. The classes below are derived from the matched path against fixed tables (a
// dataset name only if it is a loaded one), never from free text. The client address is used
// for one purpose: a per-minute map address -> count, from which two numbers survive (how
// many distinct clients, the most requests from one); the map is dropped when the minute
// rolls over and is never logged, marshalled or returned.

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	usageMinutes    = 1440  // the ring: the last 24 h, one slot per minute
	usageDaysKept   = 400   // per-day totals since start, bounded for a very long uptime
	usageClientsCap = 50000 // per-minute address map bound; beyond it new addresses are not told apart
)

var latencyKeys = [5]string{"le10ms", "le50ms", "le200ms", "le1s", "gt1s"}

// counts: what is counted per minute and per day.
type counts struct {
	Requests   int            `json:"requests"`
	ByEndpoint map[string]int `json:"by_endpoint,omitempty"`
	ByDataset  map[string]int `json:"by_dataset,omitempty"`
	ByStatus   map[string]int `json:"by_status,omitempty"`
	ByClient   map[string]int `json:"by_client,omitempty"`
	Latency    map[string]int `json:"latency,omitempty"`
	Bytes      int64          `json:"bytes"`
	Busy       int            `json:"busy,omitempty"`
}

func (c *counts) add(endpoint, dataset, status, client string, lat int, bytes int64, busy bool) {
	c.Requests++
	inc := func(m *map[string]int, k string) {
		if *m == nil {
			*m = map[string]int{}
		}
		(*m)[k]++
	}
	inc(&c.ByEndpoint, endpoint)
	if dataset != "" {
		inc(&c.ByDataset, dataset)
	}
	inc(&c.ByStatus, status)
	inc(&c.ByClient, client)
	inc(&c.Latency, latencyKeys[lat])
	c.Bytes += bytes
	if busy {
		c.Busy++
	}
}

func cloneMap(m map[string]int) map[string]int {
	if len(m) == 0 {
		return nil
	}
	o := make(map[string]int, len(m))
	for k, v := range m {
		o[k] = v
	}
	return o
}

func (c counts) clone() counts {
	c.ByEndpoint, c.ByDataset, c.ByStatus = cloneMap(c.ByEndpoint), cloneMap(c.ByDataset), cloneMap(c.ByStatus)
	c.ByClient, c.Latency = cloneMap(c.ByClient), cloneMap(c.Latency)
	return c
}

func (c *counts) merge(o counts) {
	c.Requests += o.Requests
	c.Bytes += o.Bytes
	c.Busy += o.Busy
	for _, p := range []struct {
		dst *map[string]int
		src map[string]int
	}{
		{&c.ByEndpoint, o.ByEndpoint}, {&c.ByDataset, o.ByDataset}, {&c.ByStatus, o.ByStatus},
		{&c.ByClient, o.ByClient}, {&c.Latency, o.Latency}} {
		for k, v := range p.src {
			if *p.dst == nil {
				*p.dst = map[string]int{}
			}
			(*p.dst)[k] += v
		}
	}
}

type minuteSlot struct {
	min      int64 // unix minute this slot holds; 0 = empty
	c        counts
	distinct int
	maxOne   int
}

type usageStats struct {
	mu      sync.Mutex
	now     func() time.Time
	known   map[string]bool // loaded dataset names
	since   time.Time
	ring    [usageMinutes]minuteSlot
	curMin  int64          // the minute `clients` belongs to
	clients map[string]int // address -> requests in curMin; dropped at rollover, never exposed
	days    []dayTotal
}

type dayTotal struct {
	date string
	c    counts
}

func newUsage(names []string, now func() time.Time) *usageStats {
	u := &usageStats{now: now, known: map[string]bool{}, since: now().UTC()}
	for _, n := range names {
		u.known[n] = true
	}
	return u
}

// classify: endpoint class and dataset name of a request, from the method and path alone.
// Anything not on the fixed list is "other" (a dataset segment that is not loaded is "other"
// too, so a scanner's guesses never become keys).
func (u *usageStats) classify(method, path, rawQuery string) (endpoint, dataset string) {
	switch path {
	case "/healthz":
		return "healthz", ""
	case "/statz":
		return "statz", ""
	case "/v1/datasets":
		return "datasets", ""
	case "/v1/contact":
		return "contact", ""
	}
	if !strings.HasPrefix(path, "/v1/") {
		return "other", ""
	}
	parts := strings.Split(path[4:], "/")
	if len(parts) != 2 {
		return "other", ""
	}
	dataset = "other"
	if u.known[parts[0]] {
		dataset = parts[0]
	}
	switch parts[1] {
	case "meta", "clinical", "values":
		return parts[1], dataset
	case "probes":
		for _, kv := range strings.Split(rawQuery, "&") {
			if kv == "all=1" {
				return "probes_all", dataset
			}
		}
		return "probes_search", dataset
	}
	return "other", dataset
}

func clientKind(ua string) string {
	switch {
	case strings.HasPrefix(ua, "T2 iOS"):
		return "ios"
	case strings.HasPrefix(ua, "T2-shiny"):
		return "web"
	}
	return "other"
}

func statusClass(code int) string {
	switch {
	case code == 304:
		return "304"
	case code == 429:
		return "429"
	case code == 503:
		return "503"
	case code >= 200 && code < 300:
		return "2xx"
	case code >= 400 && code < 500:
		return "4xx"
	case code >= 500:
		return "5xx"
	}
	return "other"
}

func latencyBucket(d time.Duration) int {
	switch {
	case d <= 10*time.Millisecond:
		return 0
	case d <= 50*time.Millisecond:
		return 1
	case d <= 200*time.Millisecond:
		return 2
	case d <= time.Second:
		return 3
	}
	return 4
}

// clientAddr: the address the per-minute map is keyed by (first X-Real-IP, else the first
// X-Forwarded-For element, else the connection's host).
func clientAddr(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-Real-IP")); v != "" {
		return v
	}
	if v := r.Header.Get("X-Forwarded-For"); v != "" {
		return strings.TrimSpace(strings.Split(v, ",")[0])
	}
	if h, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return h
	}
	return r.RemoteAddr
}

// record counts one finished request.
func (u *usageStats) record(endpoint, dataset, status, client, addr string, lat int, bytes int64, busy bool) {
	t := u.now().UTC()
	m := t.Unix() / 60
	u.mu.Lock()
	defer u.mu.Unlock()
	slot := &u.ring[m%usageMinutes]
	if slot.min != m {
		if slot.min > m { // a clock that stepped back: keep the newer slot, count only in the day
			u.dayFor(t).add(endpoint, dataset, status, client, lat, bytes, busy)
			return
		}
		*slot = minuteSlot{min: m}
	}
	slot.c.add(endpoint, dataset, status, client, lat, bytes, busy)
	if m != u.curMin {
		u.curMin, u.clients = m, map[string]int{} // the previous minute's addresses are dropped here
	}
	if n, seen := u.clients[addr]; seen || len(u.clients) < usageClientsCap {
		u.clients[addr] = n + 1
		slot.distinct = len(u.clients)
		slot.maxOne = max(slot.maxOne, n+1)
	}
	u.dayFor(t).add(endpoint, dataset, status, client, lat, bytes, busy)
}

func (u *usageStats) dayFor(t time.Time) *counts {
	d := t.Format("2006-01-02")
	if n := len(u.days); n == 0 || u.days[n-1].date != d {
		u.days = append(u.days, dayTotal{date: d})
		if len(u.days) > usageDaysKept {
			u.days = u.days[1:]
		}
	}
	return &u.days[len(u.days)-1].c
}

// usageWriter remembers the status and the bytes written, and lets `limited` flag a refusal.
type usageWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
	busy   bool
}

func (w *usageWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *usageWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}

func (w *usageWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// metered is the outermost middleware, so that requests refused by `limited` are counted too.
func (s *server) metered(next http.Handler) http.Handler {
	u := s.usage
	if u == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t0 := u.now()
		uw := &usageWriter{ResponseWriter: w}
		next.ServeHTTP(uw, r)
		if uw.status == 0 {
			uw.status = http.StatusOK
		}
		ep, ds := u.classify(r.Method, r.URL.Path, r.URL.RawQuery)
		u.record(ep, ds, statusClass(uw.status), clientKind(r.Header.Get("User-Agent")), clientAddr(r),
			latencyBucket(u.now().Sub(t0)), uw.bytes, uw.busy)
	})
}

// ---------------------------------------------------------------------------------------
// views

type minuteView struct {
	T string `json:"t"`
	counts
	Distinct int `json:"distinct_clients"`
	MaxOne   int `json:"max_per_client"`
}

type dayView struct {
	Date string `json:"date"`
	counts
}

type usageView struct {
	Since   string       `json:"since"`
	Minutes []minuteView `json:"minutes"`
	Today   dayView      `json:"today"`
	Days    []dayView    `json:"days"`
}

func minuteStamp(m int64) string { return time.Unix(m*60, 0).UTC().Format("2006-01-02T15:04Z") }

// snapshot copies under the lock; the caller marshals outside it.
func (u *usageStats) snapshot() usageView {
	u.mu.Lock()
	defer u.mu.Unlock()
	now := u.now().UTC()
	cur := now.Unix() / 60
	v := usageView{Since: now.Format(time.RFC3339), Minutes: make([]minuteView, 0, 60), Days: []dayView{}}
	v.Since = u.since.Format(time.RFC3339)
	for m := cur - 59; m <= cur; m++ {
		mv := minuteView{T: minuteStamp(m)}
		if s := u.ring[m%usageMinutes]; s.min == m {
			mv.counts, mv.Distinct, mv.MaxOne = s.c.clone(), s.distinct, s.maxOne
		}
		v.Minutes = append(v.Minutes, mv)
	}
	v.Today = dayView{Date: now.Format("2006-01-02")}
	for _, d := range u.days {
		v.Days = append(v.Days, dayView{d.date, d.c.clone()})
		if d.date == v.Today.Date {
			v.Today.counts = d.c.clone()
		}
	}
	return v
}

// ---------------------------------------------------------------------------------------
// hourly record

type hourRecord struct {
	T string `json:"t"`
	counts
	DistinctMax int `json:"distinct_clients_max"`
	MaxOne      int `json:"max_per_client"`
}

// hour sums the 60 minutes starting at hourStart (a whole hour, UTC).
func (u *usageStats) hour(hourStart time.Time) hourRecord {
	u.mu.Lock()
	defer u.mu.Unlock()
	first := hourStart.Unix() / 60
	h := hourRecord{T: minuteStamp(first)}
	for m := first; m < first+60; m++ {
		if s := u.ring[m%usageMinutes]; s.min == m {
			h.counts.merge(s.c)
			h.DistinctMax = max(h.DistinctMax, s.distinct)
			h.MaxOne = max(h.MaxOne, s.maxOne)
		}
	}
	return h
}

// line: numbers only.
func (h hourRecord) line() string {
	pct := func(k string) int {
		if h.Requests == 0 {
			return 0
		}
		return (h.Latency[k]*100 + h.Requests/2) / h.Requests
	}
	return fmt.Sprintf("usage %s requests=%d ios=%d web=%d other=%d values=%d 429=%d 503=%d busy=%d "+
		"p_latency: ≤10ms=%d%% ≤50ms=%d%% ≤200ms=%d%% ≤1s=%d%% >1s=%d%% distinct_clients_max=%d max_per_client=%d",
		h.T, h.Requests, h.ByClient["ios"], h.ByClient["web"], h.ByClient["other"], h.ByEndpoint["values"],
		h.ByStatus["429"], h.ByStatus["503"], h.Busy,
		pct("le10ms"), pct("le50ms"), pct("le200ms"), pct("le1s"), pct("gt1s"), h.DistinctMax, h.MaxOne)
}

// emitHour logs the hour's record and, if dir is set, appends it to usage-YYYY-MM.jsonl.
func (u *usageStats) emitHour(hourStart time.Time, dir string) {
	h := u.hour(hourStart)
	log.Print(h.line())
	if dir == "" {
		return
	}
	b, err := json.Marshal(h)
	if err == nil {
		var f *os.File
		f, err = os.OpenFile(filepath.Join(dir, "usage-"+hourStart.UTC().Format("2006-01")+".jsonl"),
			os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
		if err == nil {
			_, err = f.Write(append(b, '\n'))
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
	}
	if err != nil {
		log.Printf("usage: hourly file not written: %v", err)
	}
}

// runHourly emits the record of each hour once it has ended.
func (u *usageStats) runHourly(dir string) {
	for {
		next := u.now().UTC().Truncate(time.Hour).Add(time.Hour)
		time.Sleep(time.Until(next) + 2*time.Second)
		u.emitHour(next.Add(-time.Hour), dir)
	}
}
