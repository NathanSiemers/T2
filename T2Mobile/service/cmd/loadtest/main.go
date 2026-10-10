// loadtest: many concurrent clients asking t2api for probe values, as a fleet of phones would.
//
//	loadtest -url http://t2api:8080 -dataset TCGA -c 200 -d 20s -pool 2000 -hot 0.8
//
// Each worker repeatedly asks for 1-3 probes. A fraction -hot of requests draw from a small
// set of "popular" probes (served from memory after first use); the rest draw from a pool of
// -pool probes (many of them never seen before: a database lookup). Reports throughput,
// latency percentiles, bytes and errors.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	base := flag.String("url", "http://127.0.0.1:8080", "service base URL")
	ds := flag.String("dataset", "TCGA", "dataset")
	conc := flag.Int("c", 100, "concurrent clients")
	dur := flag.Duration("d", 15*time.Second, "duration")
	pool := flag.Int("pool", 2000, "number of distinct probes to draw from")
	hot := flag.Float64("hot", 0.8, "fraction of requests for the 50 most popular probes")
	gz := flag.Bool("gzip", true, "ask for gzip, as real clients do")
	seed := flag.Int64("seed", 1, "which probes make up the pool (same seed = same probes)")
	think := flag.Duration("think", 0, "pause between a client's requests (0 = none: flat out). 10s models a scientist at the app")
	open := flag.Bool("open", false, "each client first fetches /meta and /clinical, as a phone opening the app does")
	flag.Parse()

	// a pool of real probe names from the service's own search
	var probes []string
	for _, q := range []string{"A", "B", "C", "D", "E", "F", "G", "H", "K", "L", "M", "N", "P", "R", "S", "T", "Z"} {
		resp, err := http.Get(fmt.Sprintf("%s/v1/%s/probes?q=%s&limit=200", *base, *ds, q))
		if err != nil {
			panic(err)
		}
		var r struct{ Probes []string }
		json.NewDecoder(resp.Body).Decode(&r)
		resp.Body.Close()
		probes = append(probes, r.Probes...)
	}
	// a fixed shuffle: every run with the same -pool asks for the SAME probes, so a second
	// run measures the service with those probes already in its memory
	rand.New(rand.NewSource(*seed)).Shuffle(len(probes), func(i, j int) { probes[i], probes[j] = probes[j], probes[i] })
	if len(probes) > *pool {
		probes = probes[:*pool]
	}
	nHot := min(50, len(probes))
	fmt.Printf("target %s dataset %s: %d clients for %s; %d distinct probes, %.0f%% of requests for %d popular ones; think %s, open %v\n",
		*base, *ds, *conc, *dur, len(probes), *hot*100, nHot, *think, *open)

	tr := &http.Transport{MaxIdleConns: *conc * 2, MaxIdleConnsPerHost: *conc * 2, DisableCompression: !*gz}
	client := &http.Client{Transport: tr, Timeout: 60 * time.Second}
	var nOK, nErr, bytes atomic.Int64
	lat := make([][]time.Duration, *conc)
	stop := time.Now().Add(*dur)
	var wg sync.WaitGroup
	for w := 0; w < *conc; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(int64(w) + time.Now().UnixNano()))
			if *open {
				for _, p := range []string{"/v1/datasets", "/v1/" + *ds + "/meta", "/v1/" + *ds + "/clinical"} {
					if resp, err := client.Get(*base + p); err == nil {
						n, _ := io.Copy(io.Discard, resp.Body)
						resp.Body.Close()
						bytes.Add(n)
					}
				}
			}
			if *think > 0 { // spread the clients over the think interval, not all at once
				time.Sleep(time.Duration(rng.Float64() * float64(*think)))
			}
			for time.Now().Before(stop) {
				if *think > 0 {
					time.Sleep(*think)
				}
				k := 1 + rng.Intn(3)
				names := make([]string, k)
				for i := range names {
					if rng.Float64() < *hot {
						names[i] = probes[rng.Intn(nHot)]
					} else {
						names[i] = probes[rng.Intn(len(probes))]
					}
				}
				u := fmt.Sprintf("%s/v1/%s/values?probes=%s", *base, *ds, url.QueryEscape(strings.Join(names, ",")))
				t0 := time.Now()
				resp, err := client.Get(u)
				if err != nil {
					nErr.Add(1)
					continue
				}
				n, _ := io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if resp.StatusCode != 200 {
					nErr.Add(1)
					continue
				}
				lat[w] = append(lat[w], time.Since(t0))
				bytes.Add(n)
				nOK.Add(1)
			}
		}(w)
	}
	wg.Wait()
	var all []time.Duration
	for _, l := range lat {
		all = append(all, l...)
	}
	sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
	pct := func(p float64) time.Duration {
		if len(all) == 0 {
			return 0
		}
		return all[min(len(all)-1, int(p*float64(len(all))))].Round(100 * time.Microsecond)
	}
	secs := dur.Seconds()
	fmt.Printf("requests ok %d (%.0f/s = %.0f/min), errors %d, data %.1f MB uncompressed-equivalent received as %.1f MB/s\n",
		nOK.Load(), float64(nOK.Load())/secs, float64(nOK.Load())/secs*60, nErr.Load(), float64(bytes.Load())/1e6, float64(bytes.Load())/1e6/secs)
	fmt.Printf("latency: median %s   p90 %s   p99 %s   max %s\n", pct(0.5), pct(0.9), pct(0.99), pct(0.9999))
}
