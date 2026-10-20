# CPTAC integration: status log

Progress notes for the addition of CPTAC as a T2 dataset (`datasets/cptac.db`). Written so a
cold restart (new session, usage limit) can continue. The approved plan is at
`/home/nathan/.claude/plans/our-t2-databases-and-unified-stardust.md` (design decisions,
file list, who does what, verification). Newest entry first.

## 2026-10-18 (session 1)

**Decisions (Nathan, 2026-10-18):** RNA bare (`CD8A`), other types suffixed (`CD8A.prot`,
`MAPK1_Y187.phospho`, `CD8A.cnv`, `TP53.mut`, `TP53.fmut`); all six types in v1; the ten
harmonized freeze cohorts only (BRCA CCRCC COAD GBM HNSCC LSCC LUAD OV PDAC UCEC); one db.
Source: CPTAC Pan-Cancer harmonized freeze v1 (BCM, GENCODE v34) from PDC
(https://pdc.cancer.gov/pdc/cptac-pancancer, GraphQL `getAllUIPancancerFiles` +
`pdcapi/file/signedURLFromUuid/<id>`), RNA TPM + survival + phenotype from the LinkedOmicsKB
S3 mirror (`cptac-pancancer-data.s3.us-west-2.amazonaws.com/data_freeze_v1.2_reorganized/`).

**Done:**
- `lib.R` and `T2Mobile/ios/T2Kit/Sources/T2Kit/PlotBuilder.swift`: plot-title words for
  `.prot` ("protein") and `.phospho` ("phosphosite"). No iOS build is uploaded (1.0 in review).
- `default_filters.R`: `cptac` presets (Tumor samples only / Normal adjacent tissue only).
- `test_multidataset.R`: CPTAC block, skipped when `datasets/cptac.db` is absent.

- Agent A: `CPTAC/00-download.R` (PDC GraphQL + signed URLs, LinkedOmicsKB mirror; idempotent),
  `CPTAC/01-profile.R` → `CPTAC/Data/profile.md` (220 KB, 11 sections), `CPTAC/open_questions.md`.
  Data (735 MB of zips, unzipped, + mirror) in `CPTAC/Data/` (gitignored). Container has internet.
- Lead: `CPTAC/SPEC.md`, the binding builder spec (sample id rule: tumor = case id, NAT = `<case>_N`;
  TPM mirror is the RNA source, restricted to the 59,361 genes common to all files; prot/phospho/cnv
  sparse=0, rna/mut sparse=1; symbol = mapping table `gene_name`; phosphosite = `SYMBOL_S123.phospho`
  with ENSP tie-break by most non-NA; fmut strings in TCGA's format; cohort_col = `cancer_type`;
  clinical union of 293 meta columns with normalised names, normals get only case-level columns).

- Agent B: `CPTAC/build_cptac.R` (full build 7.6 min, 7 GB), `CPTAC/test_cptac.R` (69 PASS),
  `CPTAC/README.md`; sql_tests 43 checks 0 FAIL; spot checks equal the source files. First build:
  1615 samples (1044 tumors, 571 normals); probes rna 59,286 / prot 15,099 / phospho 126,602 /
  cnv 19,657 / mut 18,715 / fmut 21,775; tcgai 117 M rows.
- Lead: verified that OV's 4 extra tumors were normal-only cases from the bare-id TPM file →
  SPEC §2 amended (bare-id TPM column is a tumor iff in the PDC RNA UQ Tumor file); fixed
  `sql_tests.R` (standalone run lacked `source("t2_api_client.R")`, regression from api-mode) and
  the `test_multidataset.R` expectation (cohort_col is `cancer_type`).

- Agent B: rebuilt with the amended rule: **1,611 samples (1,040 tumors, 571 normals)**, OV 83 tumors;
  test_cptac.R 70 PASS, sql_tests 0 FAIL (1 WARN expected for the sparse=0 types). 6.97 GB, 7.8 min.
- Lead: reviewed build_cptac.R (accepted); independent spot checks against the source files pass
  (UCEC NX3_N TP53.prot, COAD 01CO005 APC fmut string, CCRCC C3L-01287 tumor/normal clinical);
  appended the 294 description lines to `T2Mobile/service/cmd/t2api/clinical_descriptions.tsv`
  (names verified against clinpheno); doc paragraphs in README.md (rebuild recipe), CODE-LAYOUT.md,
  MULTIDATASET.md ("The datasets so far"), T2Mobile/NOTES.md (log entry 2026-10-18).

- Agent C (integration, logs `/scratch/nathan/R/T2-devdata/logs/cptac-20261018/`): service image
  builds with the descriptions; four datasets load (cptac 1.35 s, 208 MB at startup); `app` 7 files
  all PASS (test_multidataset 22 PASS), `browser-service` ALL PASS, `go` ok, `swift` 58 tests ok;
  `equiv` 48/48 probes equal gitr(); presets 1040 / 571. ONE finding: the variable menu differed by
  one entry ("subtype") between files and service because `dataset_meta.subtype_col = ""` stayed ""
  in `dataset_registry.R` but became NA in `t2_api_client.R`.
- Lead: fixed `dataset_registry.R` (empty cohort_col/subtype_col/sampletype_col → NA, as the api
  client does); replaced the phosphosite example `AKT1_S473` (not in the data) by `MAPK1_Y187.phospho`
  everywhere; rebuilding the db for the new `types.example`.

- Rebuilt (7.7 min, 6.97 GB, same counts); test_cptac.R 70 PASS, test_multidataset.R all PASS.
- Agent C rerun: `app` all PASS; `equiv` and `app-service` still failed on the variable menu because
  `lib.R` hard-coded the `subtype` handle. Lead fixed `lib.R` (`subtype` only when the dataset has a
  subtype role); file-path menus: TCGA 135,643, Toil 58,590, cptac 261,430 (261,429 unique, = service),
  DEMO 51. Dev service memory with four datasets: 285 MB of 4 GB after the equiv suite.

- Agent C final rerun (logs `T2-devdata/logs/cptac-20261018-c/`): `equiv` ALL PASS, `app` all seven
  files PASS, `app-service` ALL PASS. Earlier in the same run: `browser-service` ALL PASS, `go` ok,
  `swift` 58 tests ok.

**Done 2026-10-18 evening:** committed on main (one commit: `CPTAC/` + the shared edits + docs).

**Deployed 2026-10-19 by Nathan** (`T2-data-20261019/`, `ops/deploy.sh service`, `data`, `code`; the live
service lists TCGA, DEMO, cptac, tcgatargetgtex). `ops/deploy.sh check` had one false FAIL: it did not
pass the live contact endpoint, so the suite expected no contact form; fixed in deploy.sh.

**The deploy recipe was:** deploy = a new `/scratch/shinyusb/T2-data-<date>/` with
`tcga.db` (hard link, as the served one is) and `datasets/` holding DEMO.db, tcgatargetgtex.db and
cptac.db; `ops/deploy.sh data <dir>`; `ops/deploy.sh service` so the service carries the CPTAC
clinical descriptions (and `ops/deploy.sh code` for the Shiny checkout: lib.R, dataset_registry.R,
default_filters.R). Watch `docker stats t2api` with four datasets (dev: 285 MB of 4 GB). The iPhone
app needs nothing. Phase 2 candidates: post-freeze PDC cohorts (SKCM, STAD, AML) via quantDataMatrix;
acetyl/ubiquityl/glyco; a `source_col` split (CPTAC-2 vs CPTAC-3).


## Dev website (2026-10-19)

A dev copy of the website runs as container `shiny-t2-dev` (image shinyt2t:2026.10, the canary's
config, the local checkout /scratch/nathan/R/T2 mounted read-only, api-mode against t2api-dev via
`T2-devdata/t2-api-mode-dev.Renviron.site`), LAN only: **http://10.1.0.1:3862/T2T/**. It picks up code
edits on the next session (Shiny Server re-sources the app per session; a new dataset needs
`docker restart t2api-dev` after copying the db into T2-devdata/datasets/). Stop: `docker rm -f shiny-t2-dev`.

## 2026-10-19: review by three Fable agents (branch `cptac-review-fixes`, PR)

Nathan: "Review all the new code to check for bugs in the next 12 minutes. 3 fable agents"; "Keep a pr
of suggested changes/fixes". Reviewers: builder logic / shared edits + tests + deploy script / data
invariants of the built db. Verdicts after the lead's fact checks:
- Not bugs: dotted bare rna names (`AL627309.1`, 22,054) are served correctly by both readers (fall
  back to probe_types; Toil has the same names) → SPEC §3 reworded. 70 samples with a survival event
  but no time are faithful to the meta files (46 tumors + their normals).
- Fixed on the branch: `sql_tests.R` resolved roles through the service when `T2_API_URL` was set and
  fell back to TCGA's map silently; `test_multidataset.R` opened the bundle path as a SQLite file
  (breaks in api-mode); `test_cptac.R` had a tautology (fmut-in-probe_types), an unfailable `|| TRUE`
  check, a check that passed on an absent column, a `chk()` that crashed on an empty source lookup,
  an unguarded `u[500]`, and ignored `T2_DATASETS_DIR`; `build_cptac.R` would store a NA TPM cell as
  0 via the collapse (now refuses NA cells), `dt[, case := case]` scoping, two env-knob edge cases;
  `00-download.R` never redid an interrupted unzip and did no zip-slip check; `deploy.sh data-stage`
  took the first of several compose paths and would copy a WAL-mode db without its sidecar.
- Data-level: 2,204 rna names with no data (0 in every sample) sat in `probes`/`allprobes` and were
  offered in the menu (Toil: 4,328). New shared `drop_t2_dataless_probes()` in `t2_views.R`, called by
  both builders; plus `probes(key)` / `samples(key)` indexes (joins by key scanned the table).
Validation: smoke build, test_cptac.R 70 PASS, sql_tests (DEMO, with T2_API_URL set), deploy dry run,
and a full rebuild into `T2-devdata/scratch/cptac-pr.db` (not into datasets/, not deployed).

## 2026-10-19 evening: PR #13 merged, cleaned database released

Merge ca7d6cf. Rebuild from main into `T2-devdata/scratch/cptac-main.db` (8.1 min, same counts as
the PR validation: 2,204 data-less names removed, probes 258,930, allprobes 259,224, 1,611 samples).
Tests: sql_tests 40 PASS / 0 FAIL / 1 WARN (sparse=0 types, expected), test_cptac 70/0; on the dev
service (`T2-devdata/datasets/cptac.db`, `dev-up`): go, equiv, app, app-service, browser-service
all PASS; test_multidataset 22 PASS. Release: verified copy into `datasets/cptac.db`, then
`deploy.sh data-stage 20261020 cptac.db` → `/scratch/shinyusb/T2-data-20261020/`, `data`, `code`,
`status` (served ca7d6cf), `check` (all PASS). Live `/v1/datasets`: cptac 259,225 probes (allprobes
+ the virtual `cohort`), 1,611 samples. No service rebuild (no service change in the PR).
Next: the dataset-contract work (plan file; `T2Mobile/docs/DATASET-CONTRACT.md` to come).
