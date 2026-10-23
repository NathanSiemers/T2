# Hardening round, started 2026-10-22 night (branch round-20261020)

Nathan: "launch 4 sonnet agents to do a complete overview of the code base, looking for bugs, injection attacks
(r/shiny or api), inefficiencies, memory leaks. Make sure this code is as robust as possible. you can work for hours
on this ... make checkpoints/notes every 15 minutes so that if you run out of resources, we can restart with little
work lost. proceed autonomously"

Rules in force: PRODUCTION FREEZE (no deploy, no ASC writes, no uploads); everything is commits on `round-20261020`
(PR #14); every fix verified with `T2Mobile/ops/test.sh` suites on the dev stack; the audited session never runs
`security/scan.sh --baseline`. This file is the restart point: read the latest checkpoint, then NOTES.md.

## How the round works

1. Review agents (Sonnet, read-only) each cover one area and report findings with file:line, severity, a concrete
   failure scenario and a suggested fix. Areas: A Go service; B R/Shiny app + api client; C R data layer (gitr file
   mode, builders, dataset_meta.R, SQL construction); D iOS + ops/shell/nginx/compose.
2. The lead verifies each finding against the code (and runs it where cheap), discards false positives, groups the
   real ones into a fix round, writes specs, and delegates fixes to Sonnet agents (one per area).
3. Suites after every fix round; commit; note here; repeat with the next series.

## Checkpoints (newest first)

### 2026-10-22 ~22:40 PDT: review A (Go service) in, fix agent A launched
- Review A: no critical/high. SQL all parameterised; JSON writer escapes everything (verified by curl with quotes,
  backslashes, invalid UTF-8, CRLF); NaN/Inf -> null; limits (100 probes, name 200, q 200, limit<=200, body 16 KB,
  in-flight 256) enforced; ETag/`v` semantics consistent; usage maps bounded; rows closed; path traversal 404.
- Fix agent A (Go) working on: middleware order gzipped(recovered) + lazy gzip only for 2xx + sync.Pool; probes search
  bounded top-k selection; probes search Cache-Control honours `v`; version string gains the SQLite change counter;
  %q in the panic log; contact: limiter before honeypot, Zl/Zp/bidi stripped, one client-address helper (last XFF);
  graceful shutdown on SIGTERM; precomputed /v1/datasets bytes + ETag. Unit tests via `ops/test.sh go`; the dev
  container is rebuilt by the lead afterwards (`ops/test.sh dev-up`) and equiv/app-service re-run.
- Round 0 (ultrareview fixes) still in `ops/test.sh all`; commit pending on its verdict.
### 2026-10-22 ~22:10 PDT: round 0 (ultrareview fixes) in test, review agents launched
- Ultrareview of PR #14 (comment 6357428844): 9 findings, all real, fixed in the working tree by three agents
  (R: t2_build_lib.R fill block moved into t2_write_types; figure_export.R list branch; lib.R t2_fill_of rows;
  survival_prototype.R rows; lib.R t2_dataset_hidden OR-rule; t2_api_client.R options from meta types.
  scan.sh: allowlist/go-deps.txt, replace/exclude/retract check, anchored repo-relative allowlist matching.
  iOS: APIClient per-chunk fill retry + 2 tests, 89 Swift tests pass). `ops/test.sh all` running
  (log /scratch/nathan/R/T2-devdata/logs/all-20261022-fixes.log); commit follows when green.
- Review agents A-D launched (read-only). Findings land in this file under "Findings" when verified.

## Findings log (verified by the lead; status: open / fixed <commit> / rejected <why>)

### Review A: Go service (2026-10-22)
| # | file | sev | finding | status |
|---|---|---|---|---|
| A1 | main.go handleProbes | medium | full sort of all matches before cut to limit; ~55 ms per q="" on TCGA; distinct q bypass the Nginx cache | fixing (agent A) |
| A2 | cache.go LRU | medium | no scan resistance: a client walking distinct probes evicts the hot set (512 MB ~ 5-6k TCGA columns) | OPEN decision: 2Q/segmented LRU, or accept (Nginx per-IP limits bound the rate) |
| A3 | main.go middleware | medium (latent) | recovered(gzipped(mux)): a panic commits 200 + gzip header before fail(500) | fixing |
| A4 | main.go gzipped | low-med | new gzip.Writer per request incl. 304/errors; 304 carries Content-Encoding | fixing |
| A5 | compose -cache-mb per dataset | low-med | 3 datasets x 512 MB cache + 48 conns x 3 x 4 MB page cache can exceed the 4g limit; SetMemoryLimit does not see sqlite memory; dev pids_limit 256 tight for 144 blocked conns | OPEN decision (compose change = after the freeze): lower -db-conns or cache_size, verify production pids_limit |
| A6 | dataset.go:144 version | low | size+mtime seconds not collision-proof; /v1/datasets has no ETag and never runs unchanged() | fixing (change counter; ETag on /v1/datasets) |
| A7 | main.go probes search | low | Cache-Control public 86400 ignores v: stale search hits up to a day after a swap | fixing |
| A8 | main.go:258 | low | panic log prints the raw path (%s) | fixing (%q) |
| A9 | contact.go | low | honeypot early return before the limiter (unbounded log lines); oneLine keeps U+2028/9 and bidi controls; XFF first vs last between contact.go and usage.go | fixing |
| A10 | cache.go key | low | `name|fill` key could collide with a probe literally named so; sparse+fill caches a duplicate copy | rejected (unrealistic names; duplicate only if such data exists) |
| A11 | Dockerfile/go.mod | low | Go 1.23 out of support since 2025-08; sqlite bump needed for a newer toolchain | OPEN decision for Nathan (dependency bump + perf re-check; not under the freeze) |
| A12 | main.go | low | /v1/datasets re-marshalled per request; no graceful shutdown | fixing |
