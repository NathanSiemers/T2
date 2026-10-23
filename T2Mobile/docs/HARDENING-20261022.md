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

### 2026-10-22 ~23:20 PDT: round 0 committed (ca81c2b); reviews C and D in; fix agents C, D-ops, D-iOS, Go-2 running
- Round 0 (the nine ultrareview fixes) committed as ca81c2b after `ops/test.sh all` all green (go, equiv 76, app 0 FAIL,
  app-service 109, browser-service, fuzz-api 6, abuse 29, fuzz-shiny 12, contact, swift 89).
- Go round A is in the working tree (uncommitted; `ops/test.sh go` green; the lead changed the honeypot handling so
  bot hits use only the per-IP budget: `allowIP`). Commit after the dev container is rebuilt (`ops/test.sh dev-up`)
  and equiv/app-service/fuzz-api/abuse re-run; the rebuild waits until agent C's equiv runs are done.
- Review C (R data layer): no SQL injection (all parameterised, index-backed); the contract check passes files with
  duplicate/NULL/orphan keys and bad roles; dataset_meta.R writes unvalidated values; served-path guard inconsistent;
  TTG builder builds in place; unchecked file.rename; sqlite_diff EXCEPT blind to duplicates; gitr phenos=FALSE skips
  filters; env_env records all env vars; no download checksums; tableget.R dead code. Agent C fixing C1-C11.
- Review D: deploy.sh data-dir regex `[0-9]*` resolves `T2-data-20261020b` to the OLDER `T2-data-20261020` (HIGH:
  the next release's data-stage would link stale files and `data` would no-op) VERIFIED; Nginx API locations define
  proxy_set_header so X-Real-IP is not inherited (contact's 5/day per-IP limit is global; usage sees one client)
  VERIFIED in nginx.conf; iOS chi-square p underflows to 0 above ~70 (HIGH, wrong statistic); no category caps in
  the app (11k-level Patient stalls the UI); loadValues ordering; no generation token; KM median vs minmin; numeric
  0/1 marker refused; URLCache; User-Agent; Column decoder validation; PrivacyInfo.xcprivacy missing;
  NSAllowsLocalNetworking in Release; deploy.sh rollback-service/api-mode off/nginx backup/allow-deploy.py scope;
  service/test.sh defaults to production; contact mail `sendmail -i`; Nginx cache fill via junk params.
  Agents: D-ops (deploy.sh fixes, FREEZE file guard, pending nginx patch), D-iOS (D1 items), Go-2 (400 on unknown
  query parameters, closes the cache-fill route service-side).
- Production-config items wait for the freeze (prepared as T2Mobile/ops/pending/): Nginx headers, error_log,
  cache key; Nginx container hardening and network segmentation are Nathan's decisions.
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

### Review C: R data layer (2026-10-22)
| # | file | sev | finding | status |
|---|---|---|---|---|
| C1 | dataset_contract_check.R | high | passes duplicate/NULL/orphan keys, types without datatypes row, bad defaults, sample_type values outside sampletype_levels (gitr -> all NA) | fixing (agent C; deep scans gated) |
| C2 | sql_tests.R:126-149, t2_views.R:154 | high latent | `NOT IN` NULL-blind; drop_t2_dataless_probes deletes allprobes but not probes when a NULL probekey exists; sql_tests defaults$default_y always NULL | fixing |
| C3 | gitr.R:313, 303-308, 148-189 | medium | sampletype factor NAs undeclared values silently; phenos=FALSE skips cohort/nonormal/noheme/rules; fill queries run for fill=na | fixing |
| C4 | dataset_meta.R | medium | no validation after write (empty title, bad cohort_col, bad tte stored); any sqlite file accepted | fixing (contract check after write, rollback) |
| C5 | builders, default_filters.R, sqlite_diff.R | medium | served-path guard only in dataset_meta.R and write_tcga_meta.R | fixing (t2_refuse_served) |
| C6 | build_tcgatargetgtex.R:128 | medium | builds in place (deletes the previous db first) | fixing (.building + rename) |
| C7 | TCGA/00-master.R:36-48, build_cptac.R:720 | medium | file.rename unchecked; `/scratch/nathan/R/T2/tcga.db` is a root-owned EMPTY DIRECTORY in this checkout (TCGA promotes to ../tcga.db while gitr reads datasets/TCGA.db) | fixing the check; the path is Nathan's decision |
| C8 | sqlite_diff.R:191-206 | medium | EXCEPT-based row diff blind to duplicates; double fingerprint error = identical | fixing |
| C9 | TCGA/290-record_environment.R | low-med | all env vars recorded into the db | fixing (allowlist) |
| C10 | TCGA/tablemaker.R:37; tableget.R | low | global con; non-transactional; tableget.R dead with a syntax error | fixing; git rm tableget.R |
| C11 | CPTAC/TTG/MSI downloads | low-med | no checksums, no .part files, TTG size mismatch only warns | fixing (sha256 manifests) |
| C12 | views vs tested.value | medium | views ignore tested.value (all current rows are 1) | contract check asserts value=1 (part of C1) |
| C13 | contract check `hidden` 0/1 vs Go 1/true/yes; doc says journal required | low | mismatch | fixing (accept both, doc) |

### Review D: iOS + ops (2026-10-22)
| # | file | sev | finding | status |
|---|---|---|---|---|
| D1 | deploy.sh:50,85 | HIGH | data-dir regex stops at `b`: stale staging, no-op `data` | fixing (agent D-ops) |
| D2 | /scratch/Docker/Nginx/nginx.conf API locations | medium (prod) | X-Real-IP not inherited: contact limit global, usage one client | patch prepared in ops/pending/, apply after the freeze |
| D3 | Stats.swift:145-169 | HIGH | chi-square upper tail = 1-(1-Q) underflows to 0 | fixing (agent D-iOS) |
| D4 | PlotBuilder.swift | med-high | no T2_LIMITS category caps | fixing |
| D5 | AppModel.loadValues | medium | filled columns shown as unfilled when the plain fetch fails | fixing |
| D6 | AppModel open/run | medium | no generation token; half-applied state; reopen loses the source part | fixing |
| D7 | deploy.sh rollback-service | medium | t2api-web keeps the bad image; minute-resolution tag | fixing |
| D8 | deploy.sh api-mode off | med-high | restores the OLDEST backup, no backup first | fixing |
| D9 | service/test.sh | medium | defaults to production; load test hits live users | fixing |
| D10 | nginx cache key | med-low | junk params fill the 4 GB cache | service 400 on unknown params (Go-2) + key from known args in the pending patch |
| D11 | deploy.sh nginx/rollback-nginx | medium | backup from the image, empty-file hazard, prefix clash | fixing |
| D12 | ops/allow-deploy.py | medium | allows every deploy.sh step without a prompt | fixing (status/check only) + FREEZE file guard in deploy.sh |
| D13-16, D19-21, D24 | iOS | low-medium | LocalizedError/offline text; live-bound baseURL; KM median minmin; 0/1 numeric marker; URLCache; User-Agent; Column validation; ForEach ids; CSV formula escaping; contact byte cap; kmMaxDays unit; PrivacyInfo.xcprivacy; NSAllowsLocalNetworking Release | fixing |
| D17-18 | Nginx container/network | low-med (prod) | error_log file in container; no cap_drop/read_only/pids/mem limits; flat network | README in ops/pending/ for Nathan's decision |
| D22-23 | contact mail, pool.sh, testflight.sh | low | sendmail `.`, STATE races; pool restart timing; upload-only version check | fixing the mail + testflight items; pool.sh is production (after the freeze) |

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
