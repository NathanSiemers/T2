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

### 2026-10-22 ~22:10 PDT: round 0 (ultrareview fixes) in test, review agents launched
- Ultrareview of PR #14 (comment 6357428844): 9 findings, all real, fixed in the working tree by three agents
  (R: t2_build_lib.R fill block moved into t2_write_types; figure_export.R list branch; lib.R t2_fill_of rows;
  survival_prototype.R rows; lib.R t2_dataset_hidden OR-rule; t2_api_client.R options from meta types.
  scan.sh: allowlist/go-deps.txt, replace/exclude/retract check, anchored repo-relative allowlist matching.
  iOS: APIClient per-chunk fill retry + 2 tests, 89 Swift tests pass). `ops/test.sh all` running
  (log /scratch/nathan/R/T2-devdata/logs/all-20261022-fixes.log); commit follows when green.
- Review agents A-D launched (read-only). Findings land in this file under "Findings" when verified.

## Findings log (verified by the lead; status: open / fixed <commit> / rejected <why>)

(none yet)
