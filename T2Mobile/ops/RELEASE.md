# From dev to production: the master runbook

What to do, in order, when something tested in the development checkout should go live. Two
kinds of change, one procedure each: **code** (the Shiny app, the Go service, the iPhone
app) and **data** (a SQLite dataset file). Most releases are one or the other; a new dataset
is usually both (a new `.db` plus the code that knows about it). Every production step is a
call of one script, `/scratch/nathan/R/T2/T2Mobile/ops/deploy.sh`, by its absolute path.

## Where things live

| place | role |
|---|---|
| `/scratch/nathan/R/T2` | the development checkout, on `main`. Edit, build and test here. `datasets/*.db` and `tcga.db` are gitignored build artifacts. |
| `/scratch/nathan/R/T2-devdata/` | the test environment: `datasets/` holds **copies** of the dataset files for the dev service, `logs/`, `screenshots/`, `scratch/` for smoke builds. Safe to delete and recreate. |
| `t2api-dev` (127.0.0.1:3861) | the development query service, mounting T2-devdata. `ops/test.sh dev-up` rebuilds and restarts it. |
| `/scratch/shinyusb/T2T` | the **served** checkout of this repo, on `main`. Never edit it; `deploy.sh code` pulls it. |
| `/scratch/shinyusb/T2-data-<YYYYMMDD>/` | the **served** data directory: `datasets/*.db` (TCGA is `datasets/TCGA.db` since 2026-10-19; older directories have a top-level `tcga.db`). Never write into one; a data release is a new directory. |
| `/scratch/Docker/ShinyPublic/docker-compose.yml` | production compose: `t2api` (the only container that mounts data), `shiny-t2t` (canary), `shiny-t2tc` pool (= the public `/T2/`), haproxy. `deploy.sh` edits it and keeps dated backups. |
| GitHub `main` | the source of truth for code. Production only ever pulls from it. |

Rule for data: build in a temporary place, test there, promote by an atomic rename or by a
new directory the compose file is switched to. Nothing served is ever modified in place.

## A. Develop and test (no production effect)

1. Work in `/scratch/nathan/R/T2`. R runs in the container:
   `docker exec -u rstudio -w /home/rstudio/R/T2 r101101-rstudio-1 Rscript <file>`.
2. **If a dataset changes or is new:** run its builder (it writes `<name>.db.building` and renames
   on success): `TCGA/00-master.R` (hours), `TCGATARGETGTEX/build_tcgatargetgtex.R` (hours),
   `CPTAC/build_cptac.R` (about 8 minutes). Smoke builds go to `T2-devdata/scratch/`, never
   into `datasets/`. Then the generic suite: `Rscript sql_tests.R datasets/<name>.db <name>`
   and the dataset's own test file (`CPTAC/test_cptac.R`, `TCGATARGETGTEX/test_tcgatargetgtex.R`).
3. Put the new file where the dev service sees it:
   `cp datasets/<name>.db /scratch/nathan/R/T2-devdata/datasets/<name>.db.staging && cmp … && mv …`
   (the dev `TCGA.db` is a hard link of the checkout's `datasets/TCGA.db`), then
   `T2Mobile/ops/test.sh dev-up` (the dev service loads datasets at start-up only).
   A dataset must pass `Rscript dataset_contract_check.R datasets/<name>.db <name>` (also run
   inside `sql_tests.R`); `dataset_meta.R set|set-json|type-label` fixes metadata on a dev copy
   without a rebuild (see `docs/DATASET-CONTRACT.md`).
4. Run the suites: `T2Mobile/ops/test.sh all` (or the relevant ones: `go`, `equiv`, `app`,
   `app-service`, `browser-service`, `swift`; logs in `T2-devdata/logs/<date-time>/`). A Sonnet
   agent can run them and report the verdict lines.
5. Optional, to look at it in a browser: a dev website over the dev service, LAN only
   (see `CPTAC/STATUS.md`, "Dev website"): `http://10.1.0.1:3862/T2T/`.
6. Commit on `main`, push to GitHub. Nothing is live yet.

## B. Release code (Shiny app, R files, service, descriptions)

Which steps apply depends on what changed:

| what changed | step |
|---|---|
| R files of the app (`app.R`, `lib.R`, `t2_api_client.R`, tests, docs, builders; the app is an api client only since 2026-10-19) | `deploy.sh code` |
| anything under `T2Mobile/service/` (Go code, `clinical_descriptions.tsv`, which is compiled in) | `deploy.sh service` |
| both | `service` then `code` |
| the iPhone app | not this runbook: Xcode / TestFlight from the Mac (`T2Mobile/NOTES.md`); never upload a build while one is in App Review |

```
cd /scratch/nathan/R/T2/T2Mobile
ops/deploy.sh service     # rebuilds the t2api image from the repo, tags the old one, restarts t2api,
                          # prints healthz and the live dataset list and a rollback line
ops/deploy.sh code        # fast-forward pulls main into /scratch/shinyusb/T2T, restarts the canary and the pool
                          # (about a minute of /T2/ downtime); refuses if the served checkout has local edits
ops/deploy.sh status      # what runs, which commit is served, which data directory, the live answers
ops/deploy.sh check       # the Chrome suite against the live /T2/ (27 checks, read-only)
```

Rollback: `deploy.sh rollback-service` (previous t2api image); for code, `git -C
/scratch/shinyusb/T2T checkout <previous commit>` followed by `deploy.sh pool-restart`, or
revert on `main` and run `code` again.

## C. Release data (a new or rebuilt SQLite dataset)

The served containers never see the development files. A data release makes a new directory
and switches the compose file to it.

```
cd /scratch/nathan/R/T2/T2Mobile
ops/deploy.sh data-stage 2026MMDD cptac.db          # 1. stage: /scratch/shinyusb/T2-data-2026MMDD/
                                                    #    tcga.db and every dataset NOT named: hard links to the
                                                    #    served files (same inodes, never written);
                                                    #    each named file: copied from the checkout's datasets/
                                                    #    under a .staging name, byte-compared, quick_checked,
                                                    #    renamed into place. Refuses an existing directory,
                                                    #    a -wal sidecar, a non-rollback journal mode.
ops/deploy.sh data /scratch/shinyusb/T2-data-2026MMDD   # 2. switch: backs up the compose file, points t2api
                                                        #    (and the sites) at the new directory, restarts them;
                                                        #    prints the rollback line
ops/deploy.sh status
ops/deploy.sh check
```

Name several files to replace more than one dataset (`data-stage 2026MMDD cptac.db
tcgatargetgtex.db`). `TCGA.db` is a name like the others (`data-stage 2026MMDD TCGA.db`, 40 GB,
10–20 min). A served directory of the old layout (top-level `tcga.db`) is staged into the new one
(`datasets/TCGA.db`), and the `data` step then drops the top-level mount and the `-tcga` flag
from the compose file; the service finds `datasets/TCGA.db` by itself.

Rollback: the `data` step prints `cp docker-compose.yml.pre-data-<stamp> docker-compose.yml
&& docker compose up -d ...`; the previous directory is untouched, so the switch back is a
restart. Old directories can be removed once nothing points at them (hard links make this
free of risk: deleting a directory never affects another).

Dry run of the staging step on scratch space: `T2_DATA_BASE=/scratch/nathan/R/T2-devdata/scratch
ops/deploy.sh data-stage 99999999 cptac.db`, then remove the directory.

## D. A new dataset end to end

1. Builder directory `<NAME>/` with a download script, a profile of the raw files, the builder
   (sourcing `t2_views.R`, `default_filters.R`, `ensembl_to_hgnc.R`), a test file, a README.
   `default_filters.R` gets the dataset's presets; `clinical_descriptions.tsv` its clinical
   columns (service rebuild); `test_multidataset.R` a block. Pattern: `CPTAC/`, `CPTAC/SPEC.md`.
2. Section A in full (build, suites against the dev service with the new file in T2-devdata).
3. Commit, push.
4. Section B (`service` for the descriptions, `code` for the R files), then section C with the
   new file named. Order: `service`, `data-stage`, `data`, `code`, `status`, `check`.
5. The iPhone app lists datasets from the service and needs nothing.

## Who runs what

`deploy.sh` is allowed for Claude by absolute path in `~/.claude/settings.json` (your request of
2026-10-11). In **manual** permission mode Claude runs each step and you approve each call. In
**auto** mode a server-side classifier judges every command and refuses anything that touches
`/scratch/shinyusb` or edits the allowed script, even steps of the script; then the commands
above are for you to run (prefix a line with `!` in the Claude session to run it there and let
Claude read the output). Loose shell commands against served paths are never the way: add a
step to the script instead, in manual mode, and commit it.

## Checklist

- [ ] tests green on the dev service (`ops/test.sh`), commit pushed to `main`
- [ ] service changed? `deploy.sh service`
- [ ] data changed? `deploy.sh data-stage <date> <files>` then `deploy.sh data <dir>`
- [ ] R code changed? `deploy.sh code`
- [ ] `deploy.sh status`, `deploy.sh check` (27 PASS)
- [ ] note the release in `T2Mobile/NOTES.md` (and the dataset's STATUS file)
