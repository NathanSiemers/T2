# Plan: apps configured by the api, not by code

Nathan, 2026-10-19: "Ideally, the api would have all information necessary to run any database
from the api, with minimal ingrained knowledge about how data should look." The apps may still
expect a few things: (a) the variable names to offer and the handles, (b) a cohort and optionally a
sub-cohort, aliased or created when the data lack them, (c) time-to-event variables declared in a
standard way, (d) little else. And: "We are trying to keep data/schema, api, and app as separate as
possible"; a database update must be "a well-factored step in the process, not some sort of
app-related time-sink."

The binding definitions are in `DATASET-CONTRACT.md` (same directory). This document is the work
plan: what is hard-coded today, what moves where, in what order, how it is verified and released.

## 1. The three layers

| layer | lives in | owns | released by |
|---|---|---|---|
| data / schema | `tcga.db`, `datasets/*.db`; builders `TCGA/`, `TCGATARGETGTEX/`, `CPTAC/`, `build_demo_dataset.R`; `dataset_meta.R` | tables, `dataset_meta`, `types.label`, `default_filters` | `deploy.sh data-stage` + `data` |
| api | `T2Mobile/service` (Go) | the only interpreter of `dataset_meta`: roles → handles, tte variables, type labels, normalized defaults, presets, sources, the typed variable list | `deploy.sh service` |
| apps | Shiny (R, repo root), iPhone (`T2Mobile/ios`) | plotting and statistics; menus and About built from `/meta` and `/probes` | `deploy.sh code`; TestFlight |

Rule: a rule that needs code is written once, in Go. The Shiny app's file mode (SQLite without
the service: builders' tests, the `equiv` suite) reads `dataset_meta` verbatim and passes it
through; it never re-derives. Effort is estimated and reported per layer, never mixed.

## 2. What is hard-coded today (surveys of 2026-10-19)

### Shiny app (R)
- Roles for TCGA in code twice: `dataset_registry.R:30-49` and `gitr.R:55-65` (`tcga.db` has no
  `dataset_meta`); introspection candidates `tumtype/cohort/group/dataset`, `Subtype_Selected/subtype`,
  `sample_type/sampletype` (`dataset_registry.R:144-155`).
- Handles by literal name: `lib.R:90-98` (`subtype`, `cohort`, the sampletype column),
  `t2_api_client.R:236-239` (`mygenes = setdiff(menu, handles)`), `gitr.R:183` virtual_cols.
- Survival: its own table `T2_ENDPOINTS` (OS/PFI/DSS/DFI, `survival_prototype.R:23-26`), time column =
  `<name>.time` (:70-71), event numeric 1/0, days everywhere (:64, :178-180, :216; `app.R:295`;
  `input_validation.R:73`); the survival switch `lib.R:853-855` and the X whitelist
  `input_validation.R:55` use the fixed names (so "OS" is accepted as X for Toil, which has none);
  `/meta$survival_endpoints` never read. About note on survival (`app.R:762-787`) is TCGA's, shown
  for every dataset.
- Title words for suffixes `lib.R:611-616`; `.mut` levels forced to 0/1 `lib.R:559-564`; literal
  `sample_type` in the complete-cases columns `lib.R:488`.
- About prose for TCGA `app.R:309-312`; every `source_url` labelled "Xena" `app.R:743-745`.
- Type inferred from the name's suffix in both modes (`gitr.R:285-315`, `t2_api_client.R:175-202`);
  the menu is a flat list of names (`allprobes` table; `/probes?all=1`), so a name's section
  (handle / probe / clinical), type and kind are unknown until its values are fetched.
- `sql_tests.R:76` reads `defaults$default_y` (key is `y`; always NULL).

### iPhone app (Swift)
- Reads nearly everything from `/meta`, but ignores `roles`; literal `cohort` (`AppModel.swift:128,
  247, 522, 538-540`, `CohortChooser.swift`) and `sample_type` (`PlotBuilder.swift:99, 201`).
- Survival labels hard-coded (`PlotBuilderSurvival.swift:16-17`), pair rule `X`/`X.time` (:23-25),
  usable iff both in `clinical_columns` (`Models.swift:198-201`), days (:105-107, :133,
  `PlotView.swift:86-93`).
- Title words `PlotBuilder.swift:550`; TCGA prose `AboutView.swift:17, 29-31, 206`;
  `defaults.cohorts` split on `,` only (`AppModel.swift:529`).
- Decoder requires `roles`, `presets`, `clinical_columns`, `survival_endpoints:[String]`,
  `defaults:[String:String]` → the api may only add fields.

### Service (Go)
- `survival_endpoints` is the constant `OS,PFI,DSS,DFI` for every dataset (`dataset.go:716`).
- `defaults.cohorts` passed through unsplit; CPTAC stores `BRCA|CCRCC|…`, the phone splits on `,`
  (`dataset.go:218-222`): CPTAC's opening cohorts never apply on the phone.
- TCGA block (`dataset.go:85-90, 186-193`): roles, title, defaults in code.
- The variable list `/probes?all=1` is a flat array of names whose order carries the meaning
  (handles first, then probes, then the sample-type column and clinical columns,
  `dataset.go:466-484`).

## 3. What moves where

| today | becomes | layer |
|---|---|---|
| TCGA roles/defaults/title in R and Go | `dataset_meta` in `tcga.db` (written by `TCGA/write_tcga_meta.R`, called by `00-master.R`; applied now to a staged copy) | data |
| fixed survival list, `T2_ENDPOINTS`, Swift labels | `dataset_meta.tte_variables` (JSON; builders) → `/meta.tte_variables`; `survival_endpoints` = its names | data → api |
| title words in R and Swift | `types.label` → `/meta.type_labels` | data → api |
| About prose in R and Swift | `dataset_meta` `about`, `citation`, `attribution`, `about_url` → `/meta.about` | data → api |
| literal handle names in R and Swift | `/meta.handles [{name, role}]`; `cohort` synthesized when a file has none | api |
| `|` vs `,` in `default_cohorts` | the file keeps `|`; the api serves commas | api |
| flat menu, type by suffix in the apps | `/probes?all=1&typed=1`: per name `section`, `type`, `kind` (columnar codes) | api |
| `sql_tests.R` key bug, `input_validation.R:55`, `lib.R:488` | consumers of the above | apps |

What stays in the apps on purpose (`DATASET-CONTRACT.md` §3): the six assumptions (variable list,
handles, tte, labels/about, preset rule semantics, full level set for numeric factors) and analysis
policy (KM excludes normals, follow-up caps, numeric-only operations, `T2_LIMITS`). The suffix rule
stays as the naming convention of the builders and as the api's way of resolving a name.

Decisions (Nathan, 2026-10-19): the sub-cohort handle keeps its visible name `subtype`, tagged role
`subcohort`; `tcga.db` gets a real `dataset_meta` now (staged 40 GB copy) rather than a legacy
block; round 1 = api + Shiny + builders + iOS code (no iOS upload while 1.0 is in App Review).

## 4. Steps, by layer

### Data / schema (≈ 0.5 day of work + copy time; a Sonnet agent)
1. `dataset_meta.R`: `set` creates the table when missing; `set-json <db> key @file.json`;
   `type-label <db> type=label …` (adds the `types.label` column if absent). Refuses a served path.
2. `TCGA/write_tcga_meta.R`: TCGA's roles, defaults, title/label (the values now in
   `dataset_registry.R:30-49`), `tte_variables` for OS/PFI/DSS/DFI (Liu et al. 2018), about/citation,
   the 19 `types.label` values. Idempotent. `TCGA/00-master.R` calls it after `250-create_views.R`.
3. `dataset_contract_check.R <db> <name>`: the conformance check of `DATASET-CONTRACT.md` §4; every
   builder runs it last; `sql_tests.R` sources it.
4. Builders: `CPTAC/build_cptac.R` (tte OS + PFI, about, the NCI attribution sentence, labels),
   `TCGATARGETGTEX/build_tcgatargetgtex.R` (`tte_variables = []`, about, labels),
   `build_demo_dataset.R` (labels, a synthetic OS/OS.time pair so every suite exercises survival).
5. Files: rebuild CPTAC (8 min) and DEMO (seconds) into scratch; apply the keys to the DEV copies of
   `tcga.db` (after `cmp` with the served copy, `t2api-dev` stopped) and `tcgatargetgtex.db` (no
   rebuild: hours). Run the conformance check on all four.

### Api (≈ 1 day; a Sonnet agent, running)
`loadRoles` keeps the raw meta; TCGA block deleted; `handles` + synthesized `cohort`; `loadTTE`
(declared, else derived pairs); `types.label` → `type_labels`; `about`; `defaults.cohorts`
normalized; typed variable list; `/datasets` gains `handles`; `contract_test.go`; `API.md`.

### Shiny app (≈ 0.5 day)
`dataset_registry.R` reads the new keys verbatim (jsonlite for the JSON key) and drops the TCGA
block; `t2_api_client.R` takes `handles`, `tte_variables`, `type_labels`, `about` and the typed
list from the service; `lib.R` builds handles and title words from them, complete-cases columns
from the handles, passes `tte`/`type_labels` into `fun_plot1`; `survival_prototype.R` reads
event/time columns, label and unit from the tte entry; `input_validation.R` whitelists the
bundle's tte names; `app.R` About from `about`/`tte`, source links by host; `sql_tests.R:76`.

### iPhone app (≈ 0.5–1 day, code only)
Optional `handles`, `tteVariables`, `typeLabels`, `about` on `DatasetMeta` (snake_case decoding
already maps the keys); `cohortColumn`/`sampleTypeColumn` by role with today's literals as
fallback; tte from the declared list (fallback: today's pair rule); title words from
`typeLabels`; About from `about`; cohorts split on `,` or `|`; typed search hits for menu rows;
decoding tests with and without the new fields.

### Tests
Go `contract_test.go`; `dataset_contract_check.R` on all four files; `test_multidataset.R`
asserts `handles`, `tte`, `type_labels`, CPTAC's attribution in both modes; the `equiv` suite
compares values and menus as today and checks that `/meta` carries what the file declares (not two
derivations); `test_gitr_api.R` compares the bundles' four new members; Swift decoding tests.

## 5. Compatibility and release

Shipped iPhone 1.0: `survival_endpoints` stays a string array, never null (TCGA identical, CPTAC
`["OS","PFI"]`, Toil `[]`); `defaults.cohorts` stays a string (the phone finally applies CPTAC's
opening cohorts; release-note it); unknown keys ignored. Each layer is safe alone: the new api
tolerates old files (fallbacks), the old api ignores the new table/column, the apps fall back
when a field is absent.

Release order (`ops/RELEASE.md`): data layer tested on the dev service (`ops/test.sh dev-up`,
`all`) → `deploy.sh service` → `deploy.sh data-stage <date> tcga.db cptac.db DEMO.db
tcgatargetgtex.db` (extend `data-stage` to accept `tcga.db` from `$REPO/tcga.db`; 40 GB copy
≈ 10–20 min) → `data` → `code` → `status` → `check`. Notes in `T2Mobile/NOTES.md`.

## 6. Status
- 2026-10-19: contract written (`DATASET-CONTRACT.md`); api agent started; data-layer agent next;
  `cmp` of the dev `tcga.db` against the served copy running.
