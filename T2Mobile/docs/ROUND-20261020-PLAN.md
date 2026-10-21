# Round 2026-10-20: the next-round TODOs, as a PR (production frozen)

Branch `round-20261020` off `main`. **Production is frozen while iOS build 1.0 (2) is with App Review**
(Nathan, 2026-10-20): no `deploy.sh` step, no data/service/Nginx/compose change, no TestFlight upload,
no App Store Connect write until Nathan lifts the freeze. Everything here is developed and tested on the
dev stack (t2api-dev 127.0.0.1:3861, dev website http://10.1.0.1:3862/T2T/, the Mac simulator) and goes
to one PR; merge and release come after the freeze.

Source of the items: `T2Mobile/NOTES.md` Status, the six TODOs of 2026-10-20. The CPTAC `.prot` zero
option stays a note (Nathan: "leave it for now").

## Items and the layer that owns each

| # | item | data | api (Go) | web app (R) | iOS |
|---|---|---|---|---|---|
| 1 | DEMO must not show in the apps | `dataset_meta` key `hidden` (`1`/`0`; builders: `build_demo_dataset.R` writes `1`; `T2_META_KEYS` gains it; `dataset_meta.R set` accepts it) | `/v1/datasets` entries gain `"hidden": true/false` (absent key = false); the dataset is still served (the suites use DEMO) | `list_sources()` skips `hidden`; fallback while the served data lack the key: name `DEMO` or title containing "not real data" (the iOS rule) | honour `hidden` in addition to `isDemo` |
| 2 | api usage metrics, DoS visibility, no sensitive data | — | in-memory per-minute counters for the last 24 h and per-day totals since start: by endpoint class (datasets, meta, clinical, probes-all, probes-search, values, contact, healthz, other), by dataset, by status class (2xx, 304, 4xx, 429, 503, 5xx), by client kind from the User-Agent prefix (`T2 iOS`, `T2-shiny`, other), latency buckets (≤10 ms, ≤50, ≤200, ≤1 s, >1 s), busy refusals; distinct clients per minute and the largest per-client count in the minute (counted from `X-Real-IP`/`X-Forwarded-For` in a per-minute set that is discarded at the minute's end, never logged, never exposed as an address). Exposed on `/statz` (internal only: Nginx routes only `/v1/` and `/healthz`) as `usage`; one log line per hour with the hour's totals (no addresses, no probe names). Optional `-usage-dir` flag: when set, one JSON line per hour appended to `usage-YYYY-MM.jsonl` (default off; the production container has a read-only filesystem, the mount comes with a later compose change). Tests. `API.md` documents it; a paragraph for the privacy page is drafted in `docs/API.md` (the page itself is in the Nginx repo, frozen). | — | — |
| 3 | plot title names the data source part | — | — | `lib.R` title: when a source part is selected, the title carries the part's label from `/meta` `source_labels` (e.g. "GTEx (Toil)" not "TCGA-TARGET-GTEX (Toil)") | `PlotBuilder` title: the selected source's label (`AppModel.sourceLabel`) |
| 4 | tone down "statistics"; survival hint prominent | — | — | About: a one-line hint near the top naming the dataset's time-to-event variables (from the bundle's `tte`: OS, PFI, DSS, DFI for TCGA; OS, PFI for CPTAC) and "choose one as X"; the same hint under the X selector; About and the help text say "plots, with a few summary statistics" and let the survival analysis carry the weight | About: the hint at the top (under Research use only, from `meta.tte`); Select screen: a footnote under X; `docs/APPSTORE.md` description/subtitle/promo/keywords reworded (listing text goes live with the next build) |
| 5 | filter description in the caption; Publish keeps/removes any text element | — | — | caption line "Filtered: …" built from the active preset(s), cohorts (count or names), Filter-tab rules, `nonormal`/`noheme`; Publish tab: a checkbox per text element (title, subtitle, caption, source line, axis titles) | caption line from the active filters (presets, cohorts, Filter screen rules); Publish screen: a switch per text element (title, subtitle, caption, attribution/source line, axis titles); the "please cite" reminder stays when the source line is off |
| 6 | "TCGA (The Cancer Genome Atlas) and other genomic databases" | — | — | About "T2" paragraph and the help text: no list of collections | `AboutView` T2 paragraph; `docs/APPSTORE.md` subtitle ("Explore TCGA, TARGET and GTEx"), description first paragraph, promotional text, keywords; the website blurb (`/scratch/Docker/Nginx/html`) is noted in NOTES.md for after the freeze |
| — | iOS build number | — | — | — | `CURRENT_PROJECT_VERSION = 3` (`T2App/Config/T2.xcconfig`); the marketing version is decided at release (1.0 if build 2 is rejected and this is the fix, 1.1 if approved) |

## Rules for the agents

- Work in the checkout `/scratch/nathan/R/T2` on branch `round-20261020`, on your layer's files only
  (Go: `T2Mobile/service/**`, `T2Mobile/docs/API.md`; R: `*.R` at the top level, `Testing/`, `www/`;
  iOS: `T2Mobile/ios/**`, `T2Mobile/docs/APPSTORE.md`). The data-layer bits of item 1 (`t2_build_lib.R`,
  `build_demo_dataset.R`, `dataset_meta.R`) belong to the R agent. **Do not commit**: the lead reviews
  and commits. Do not touch `/scratch/shinyusb`, `/scratch/Docker`, the Mac's App Store Connect tooling,
  or the production containers.
- The dev DEMO file already carries `hidden=1` (written 2026-10-20 into
  `/scratch/nathan/R/T2-devdata/datasets/DEMO.db`). The dev service is rebuilt from the checkout with
  `T2Mobile/ops/test.sh dev-up` (Go agent runs it when the service compiles; the R agent may run it too).
- Tests are the acceptance criteria. Go: `T2Mobile/ops/test.sh go` (unit) and, after `dev-up`,
  `fuzz`, `equiv`. R: `test.sh app` (shinytest2 suites in the R container), `app-service`,
  `browser-service` (headless Chrome against the dev website). iOS: `test.sh swift` (T2Kit unit tests in
  the swift container) and `test.sh ios` (Mac simulator, iPhone 18 Pro; XcodeGen runs in `sim_matrix.sh`).
  Add tests for every new behaviour (hidden filtering, title label, caption text, publish switches,
  usage counters, UA classification). All suites green before the hand-back, or say exactly what fails.
- Privacy promise (NOTES.md, the App Store privacy answers): no addresses, no selections, no probe
  names in any log or file. Item 2 must keep that: counts only.
- Keep the apps' assumptions minimal (DATASET-CONTRACT.md): dataset knowledge comes from `/meta` and
  `/v1/datasets`, never from literals (the DEMO name fallback in the R app is the one documented
  exception, removed once the served data carry `hidden`).

## Status

- 2026-10-20 evening: branch created, dev DEMO marked hidden, three agents started (Go, R, iOS).

## Item 7 (added 2026-10-20 evening): not-detected values as zero or the detection floor, as an option

Nathan: "idealize and implement an improvement in the code where for proteomics (or any relevant data type)
tested but not available can be treated as zero (in an option). Samples which were not analyzed always remain
NA." And: "the ui must be elegant, only offering this option where it is applicable."

Background: NOTES.md TODO "CPTAC `.prot` missing values" (CLDN6.prot: 192 of 1,549 proteome samples; a
missing cell = no quantifiable PSM in that TMT plex = below the detection floor, and the missing samples are
the low expressers). Today a `sparse = 0` type (prot, phospho, cnv, fmut, rppa, pc_gene_program) serves a
tested sample without a stored row as NA; a `sparse = 1` type serves its default (0). Untested samples are NA
in every case and stay so.

### Contract (data → api → apps; the api is the only interpreter)

**Data.** `types` gains an optional column **`fill_options`**: `|`-separated subset of `na|zero|floor`,
in display order, `na` first; absent column or NULL = `na` only. Meaning: for a probe of this type, a sample
that was tested for the type but has no stored value may be served as NA (default), as 0 (`zero`) or as the
detection floor (`floor` = the minimum stored value of that probe among the tested samples of the same
cohort (`cohort_col`); a cohort with no stored value for the probe uses the probe's dataset-wide minimum).
Builders: `CPTAC/build_cptac.R` writes `na|zero|floor` for `prot` and `phospho`, `na` for the rest;
`t2_build_lib.R` gets the helper and `T2_FILL_OPTIONS <- c("na","zero","floor")`; `dataset_contract_check.R`
validates the column (subset, `na` first, only on `sparse = 0` types); `dataset_meta.R type-fill <db>
prot=na|zero|floor ...` adds/updates the column on an existing file (for the served cptac.db at release
time, through a staged copy as always). The dev `cptac.db` gets it now (dev data; t2api-dev stopped while
writing). TCGA/Toil/DEMO: untouched (`na` only; their dense types are not "not detected" semantics).

**Api.** `/v1/{ds}/meta`: each `types[]` row gains `fill_options: ["na","zero","floor"]` (always present,
`["na"]` when the data say nothing); `type_labels`-style convenience map `fill_options: {type: [...]}` is NOT
added (the row is enough). `/v1/{ds}/values?v=&probes=…&fill=zero|floor` (default `na`; any other value →
400): applied per probe, only to probes whose type lists that fill; other probes in the same request are
served unchanged. The answer gains `"fill": "zero"` (echo, absent for `na`) and `"filled": {"CLDN6.prot": 1357}`
(cells changed per probe, only for probes where > 0). Untested samples are never filled. Implementation:
`fetchProbe(name, fill)`; the column cache keys `name|fill` so each variant is computed once; `floor` needs
the cohort of every sample row (from the clinical frame loaded at start) and two passes over the rows.
Cache/ETag: the `cacheable` key includes `fill`; `?v=` answers stay immutable (the fill is a pure function
of the version); Nginx's cache keys on the full request URI already. `API.md` and `DATASET-CONTRACT.md`
document the column, the parameter and the two fills. Tests: a fixture with a `fill_options` column, zero
and floor per cohort, untested stays NaN, fill on an unsupported type is a no-op, bad fill → 400, the
`filled` counts, the ETag differs by fill.

**Web app (R).** `t2_api_values(ds, probes, fill)` → `gitr_api(..., fill = "na")` → `gitr(..., fill)`; the
FILE mode `gitr()` implements the same two fills from `tested`, `types.fill_options` and the cohort column
(the equiv suite compares both; `test_gitr_api.R` gains fill cases). UI (Plot tab sidebar): a compact
`radioButtons` "Not-detected values" (Missing · Zero · Detection floor) rendered ONLY when at least one chosen
variable (x, y, color, size, facet) is of a type whose `fill_options` has more than `na`; it disappears when
none is; the choice is per session (not global state carried to a dataset without it). The caption gains
"Not-detected protein values set to 0 (1,357 of 1,549 proteome samples)" / "… set to the detection floor
(per cohort)". Publish inherits the caption. Help/About: one sentence under the data type (the type
description already says "Missing when the protein was not quantified").

**iOS.** `DataTypeInfo.fillOptions: [String]?`; `AppModel.fill` (per dataset+plot, reset to `na` on a data
source switch); Select screen: a segmented control "Not detected: Missing | Zero | Floor" shown ONLY when a
chosen variable's type offers it (SwiftUI `if`), with a one-line footnote ("Tested samples without a
measured value; samples never analyzed stay missing"); `APIClient.values(..., fill:)` adds `&fill=`; the
on-device cache key includes the fill; `PlotBuilder` caption line as the web app's; Publish inherits.
Accessibility id `fill-picker`; UI test on CPTAC (CLDN6 vs CLDN6.prot): picker present, pick Zero, n in the
stats rises; on TCGA the picker is absent. Unit tests: decoding `fill_options`, caption text.

### Order
Queued behind the three running agents (they own the same files): the Go agent gets item 7 (api) as a
follow-up when it reports; the R agent the data + web part; the iOS agent the phone part. Lead writes the
dev cptac.db column (dataset_meta.R type-fill) once the R agent has added the CLI.
