# Review 2026-10-19 (b): inefficient computing

Sonnet reviewer, read-only, with measurements against the dev service (old binary; a build was
running, so timings carry noise) and `sqlite3 -readonly` query plans. Lead's verdicts in each header.

## Ranked (biggest win per effort first)

1. **R row-wise median via `apply(1, median)`** (lib.R:446 multi-X; marker_ops.R:28 multi-Y) — accepted (quick win).
   627 ms for 12.8k × 10 with NAs vs 3.3 ms with `matrixStats::rowMedians(na.rm=TRUE)` (190×; same
   result incl. NA for all-NA rows). matrixStats is in the rstudio container; confirm in the shiny image.
2. **Ranked selectize search lowercases all 259k names per keystroke** (t2_search.R:21) — accepted.
   `tolower` 0.21 s; one rank call 0.22–0.41 s; `grepl(fixed)` on pre-lowercased names 9 ms. Fix:
   lowercase once per bundle, one shared data object for the 7 selectors (app.R:424-430); or in api
   mode use the service's `/probes?q=` (8–30 ms).
3. **Go gzips every warm response on the fly** (main.go:146-157, BestSpeed per request) — accepted.
   Warm cptac `probes?all=1` 4–6 ms raw vs 56–59 ms gzipped; `clinical` 3 vs 39–48; Toil 5 cached
   probes 2.6–3.5 vs 48–73 ms: gzip is ~95 % of warm latency. Fix: precompress the static blobs once
   (level 9) at load; store a gzip member per cached column and concatenate members for `/values`.
4. **`gitr_api` factorizes and re-levels the whole clinical frame per call** (t2_api_client.R makefactors
   block) — accepted. TCGA 149 + 51 ms per plot on columns the plot never uses. Fix: cache the
   pre-factored frame per (dataset, version); droplevels only on used columns.
5. **Thanos `fetch` calls `gitr(probes)` with `phenos=TRUE`** (t2_thanos.R:116) then drops the clinical
   columns — accepted. Fix: `phenos=FALSE, makefactors=FALSE` or `t2_api_values` directly (~200 ms per
   variable change on TCGA).
6. **Go `/probes?q=` linear scan + two sorts per request** (main.go:343-378) — accepted. cptac q=a 78 ms
   (104,728 matches). Fix: `order []int32` sorted once at load by (len, name); scan it and stop at
   `limit` per class; ordering identical (testable). 80–100 ms → 8–10 ms worst case.
7. **Go `/values` fetches columns serially, 3 queries per cold probe** (main.go ~440; dataset.go:933-1031)
   — accepted. Toil cold probe 65–72 ms (CLI 14–20 ms, the rest driver + boxing); 10 cold TCGA probes
   80 ms serially. Fix: errgroup fan-out (~8), `keyToRow` as `[]int32` by samplekey, drop `ORDER BY
   rowid` on the probe_types lookup (EXPLAIN shows a TEMP B-TREE), optional in-memory (probekey, type)
   map at load. ~3–5× for multi-probe cold requests.
8. **iOS builds the plot scene and recomputes masks inside view bodies** (PlotView.swift:37, :187;
   PublishView.swift:37; AppModel.swift:401-420, 455-468) — accepted (iOS step). `scene()` and the
   group/exclusion choices rerun on every redraw; `selectedCount()` 3+ times per body. Fix: cache
   scene, choices and mask keyed by a revision counter bumped on real changes.
9. **R client parses JSON to lists, then loops** (t2_api_client.R `t2_api_get` simplifyVector=FALSE,
   `t2_api_vector` vapply) — accepted. Toil 5 columns 193 ms → 63 ms; cptac `probes?all` 527 → 192 ms;
   clinical 677 → 228 ms. Fix: `simplifyVector=TRUE` for /values, /probes, /clinical (null → NA);
   keep FALSE for /meta. Pin NA/integer/double types in test_gitr_api.R.
10. **App startup parses and holds every dataset's bundle** (app.R:159 `list_sources()`) — accepted.
    ~2 s JSON parsing per replica start; tens of MB per process. Fix: build the dataset menu from
    `/v1/datasets` (already carries sources), load a bundle when its dataset is opened; drop the
    `probes` alias of `mygenes`.
11. **Typed variable list load queries** (dataset.go probeTypeCodes / buildTyped) — verdict: acceptable
    (`probes ⋈ probe_types` 0.10 s on cptac, 0.32 s on TCGA). Trim: do not duplicate the 259k-name
    array in a second blob (→ one blob, already sent to the api agent); fill arrays in probeNames order
    from one LEFT JOIN, intern type strings.
12. **Builder: probe_types and the dataless check scan the full fact table after insert** (t2_views.R:28,
    :139) — accepted (builder step). cptac build 8.1 min: 3.5 min inserts, 32 s clinpheno, **4.1 min**
    "probe_types, indexes, views" untimed. Fix: record (probekey, type) and the has-data set in R while
    inserting (`assign_keys` already tracks `probe_type_env`); add `say()` timings around each
    finalize step. Likely 1–2 min saved on cptac, more on Toil/TCGA. probe_types must be identical.
13. **Database layout: the `tcgai` heap is dead weight in serving** — deferred, Nathan's decision
    (future rebuilds). Every view and service query is `SEARCH … USING COVERING INDEX tcgaiidx_pts`;
    the table is never read, so ~half the bytes (40.9 GB tcga.db, 6.97 GB cptac) are a duplicate copied
    on every deploy. Fix for new builds: `tcgai` WITHOUT ROWID with PRIMARY KEY (probekey, type,
    samplekey) holding value (insert sorted); optional integer type code. ~40–45 % smaller files.
    Try on cptac and Toil first; all gitr/equiv checks must pass.
14. **Float noise inflates payloads** (cptac RNA `0.37000000000000005`; Toil 16–17 digits, 350 KB per
    probe, gzip 2.1×) — needs Nathan's decision (data change). Fix at build time (`round(x, 6)` in the
    collapse step) so api and gitr() stay identical; document the rule. ~2× smaller payloads/caches.
15. **iOS CrossFilter recomputes leave-one-out masks per histogram** (Filtering.swift:145-175,
    FilterView.swift:56, :86) — accepted (iOS step). O(F² × n) per update while dragging. Fix: per
    update count failing filters per sample once, derive each leave-one-out mask; cache min/max/bins
    and levelsPresent per base-mask revision.
16. **iOS `APIClient.values` fetches chunks sequentially** (APIClient.swift:46-57) — accepted. TaskGroup
    for ≥ 2 chunks, order preserved.
17. **Go: three copies of each clinical column; `cacheable` hashes the name list per request** — not
    worth acting on (small).

## Measured baseline (dev service, same host)
| request | time |
|---|---|
| cptac values CD8A, CD8A.prot, TP53.mut (gzip, mostly cached) | 17 ms |
| cptac / TCGA values, 1 cold probe | 1.8–3.4 / 1.6–12 ms |
| TCGA values, 10 cold probes | 80 ms, 359 KB |
| Toil values, 1 cold probe (19k samples) | 65–72 ms (364 KB) |
| Toil 5 probes warm: gzip / raw | 48–73 / 2.6–3.5 ms |
| cptac probes?q=cd8 / q=a / q=1 / q=e | 8–14 / 78 / 59–97 / 31 ms |
| cptac probes?all=1 gzip / raw (1.21 / 4.31 MB) | 56–59 / 4–6 ms |
| cptac clinical gzip / raw (804 KB / 2.83 MB) | 39–48 / 3 ms |
| service start, 4 datasets | ≈ 4.3 s (TCGA 2.0, cptac 1.35, Toil 0.45) |
| RSS | prod 173 MB, dev 366 MB (limit 4 GiB); cache 1–33 MB per dataset of 512 MB, 0 evictions |
| R: rank search 259k names "cd8"/"a"/"tp53" | 0.25 / 0.41 / 0.22 s |
| R: apply(1, median) vs rowMedians (12.8k × 10) | 627 vs 3.3 ms |
| R: factor + droplevels clinical frame TCGA / Toil / cptac | 149+51 / 100+20 / 26+21 ms |
| R: parse clinical TCGA / cptac / Toil (list mode) | 0.43 / 0.20 / 0.10 s |

## Not worth it (reviewer; lead agrees)
Startup load order (0.45–2 s per dataset, once); `loadTTE` checks (µs); the contract check (touches
clinpheno, probe_types GROUP BY, DISTINCT tcgacati: no 40 GB scan; `allprobes(probe)` has no index but
is ms); cache design (O(1) LRU, correct single-flight, no pressure); indexes (none missing;
`tested_type` redundant, tiny); ANALYZE; 48 conns × 4 MiB page cache; a curl handle per request;
`gitr_memo`; the plotter pipeline (ggplot dominates); the direct-SQLite gitr() path (fast, not in
production).
