# Review 2026-10-19 (a): lack of generalized functions

Sonnet reviewer, read-only, at commit d805618 plus the in-flight api/data-layer edits. Nathan:
"look at the existing code and suggested changes, looking for (a) lack of generalized functions".
Lead's verdicts are in the header of each item: **accepted** (goes into APP-CONFIG-PLAN.md),
**deferred** (right, later), **rejected** (with the reason). Sizes: S < half a day, M ≈ a day, L days.

## 1. File mode vs api mode is two implementations; "pass-through" cannot hold as written (L) — accepted, decision pending
`gitr()` (gitr.R:153-339) vs `gitr_api()` (t2_api_client.R:151-207): the same steps in the same order
(virtual columns, `t2_sample_keep`, keep mask, re-levelling, factor typing, droplevels). Bundle:
`.read_dataset_bundle` (lib.R:48-109) vs `t2_api_bundle` (t2_api_client.R:232-266). Descriptor:
`.resolve_roles` (dataset_registry.R:100-156) vs `t2_api_resolve` (t2_api_client.R:214-229). Presets
and sources: t2_presets.R:62-150 vs dataset.go:739-831 + sources.go:114-223 ("change both or neither").
The bundle needs handles, presets, sources, the typed list, tte and type_labels, all of which are
DERIVED by the api; file mode can only be pass-through if either (a) the interpreter is callable on a
file (`t2api dump <db>` → meta.json/probes.json/clinical.json read by the R adapter), or (b) the app is
api-only and `gitr()` becomes the test oracle in `Testing/`, deleting t2_presets.R. Proposed:
`t2_source(ds)` (file or api) → `meta(), clinical(), values(probes)`; `t2_frame(src, …)` once;
`t2_bundle(src)`. Risk high; the equiv suite is the net.

## 2. types / datatypes / sparse / label are one concept written in three places per builder (M) — accepted (in flight)
CPTAC build_cptac.R:634-655 (+ set_t2_sparse block), Toil :140-147 + :225, DEMO :62-85 + :181, TCGA
tablemaker.R:103-126 + 295-type_descriptions.R:7-35 (five ALTER blocks). Proposed `t2_write_types(con,
spec)` with spec = data.frame(type, description, example, reference, source_url, source_file, label,
r_datatype, sparse, default_value) and `t2_ensure_columns(con, table, cols)`. Verify datatypes/sparse
byte-identical on tcga.db.

## 3. dataset_meta is written five ways (M) — accepted (in flight)
CPTAC :657-665, Toil :214-253, DEMO :139-153 (parallel key/value vectors paired by position), the
planned write_tcga_meta.R, dataset_meta.R `put()` with three copied transaction blocks. Proposed
`t2_write_meta(con, meta = list(...), tte = list(t2_tte(...)))` in t2_build_lib.R; the key list shared
with dataset_contract_check.R and Go.

## 4. The rest of the builder pipeline belongs in t2_build_lib.R (M–L) — accepted, after the contract round
Atomic promote (CPTAC `.building` + rename; Toil and DEMO write OUT directly, breaking the rule);
dimension tables; clinpheno UTF-8 cleaning (CPTAC:603, Toil:110, and Go `cleanText` dataset.go:171-186
re-cleaning on every load → a conformance check instead); `tested`; chunked fact inserts; probe key
assignment; cohorts table (four `cohortstring` formats); finalize (DEMO skips build_t2_probe_types and
drop_t2_dataless_probes). Proposed `t2_build_open/close`, `t2_write_dims`, `t2_write_tested`,
`t2_insert_numeric`, `t2_write_cohorts`, `t2_finalize`. TCGA's tablemaker excluded.

## 5. Suffix→type, labels, levels and `.mut` knowledge in code (M) — accepted
gitr.R:286-312, t2_api_client.R:178/198, dataset.go `declaredType`, lib.R:559-564 (`.mut` → levels 0/1),
lib.R:612-616 and PlotBuilder.swift:550 (words), gitr.R:328-331 legacy `ends_with('mut'|'cnc')`.
Proposed: `datatypes(type, r_datatype, levels)` with `levels = 0|1` for mut (replaces the special
case); `types.label`; ONE `typeOfName()` in Go (probe_types/tcgacati first, suffix as fallback for
names without data); clients read kind/type/levels from the typed list and never parse a suffix.

## 6. Group / exclusion / cohort choice logic three times (M) — accepted (api computes `choices`)
sources.go:114-223; t2_presets.R:114-179 + app.R:358 + input_validation.R:85-95; AppModel.swift:380-421
+ :127-133 + Filtering.swift. Derived presets (t2_presets.R:70-105 vs dataset.go:794-831) exist only
because old files lack default_filters. Proposed: Go adds per-source `choices: {"": [...], "<group>":
[...]}` (additive) so clients only apply rules; write default_filters into all four files and delete
derivePresets/ensureHemePreset in Go and R; keep one mask function per language. Note
`availableCohorts` (phone) reflects active exclusions, unlike `Source.cohorts`: decide first.

## 7. Virtual cohort/subtype/lcohort synthesis in four places; `role_has` in six (S–M) — accepted
gitr.R:71-83, dataset.go:312-338, default_filters.R:83-92 (own fallback tumtype/Subtype_Selected), Go
makeHandles; `role_has` test in gitr.R:72-75/97-100/168-171, t2_api_client.R:156, sql_tests.R, lib.R:94-97.
Proposed `t2_role(roles, key)` in t2_util.R; Go is the only synthesizer; no Swift fallback.

## 8. List parsing: four rules, and a comma-join that corrupts data (S, bug class) — accepted
`.split_meta` (`|` else `,`), Go `splitMeta` (same), contract check `splitl` (`|` only), Go `joinCohorts`
and Swift split on `,`. Bug: cohort values can contain commas (Toil's "Acute Myeloid Leukemia, Induction
Failure Subproject"). Proposed: arrays on the wire (`default_cohorts: [..]` additive; the comma string
only for the shipped 1.0); delete the comma fallbacks after the four files are migrated; the contract
check rejects comma-only lists.

## 9. `%||%` defined six times with two meanings; the last wins (S, latent bug) — accepted (quick win)
NA-aware in dataset_registry.R:21, t2_api_client.R:211, dataset_contract_check.R:25, test_shiny_fuzz.R:21;
NULL-only in survival_prototype.R:270, sourced last, so it is the one in force in the app. Example:
app.R:381 `chosen_group(b) %||% ""` with character(0). Proposed: one NA-aware definition in t2_util.R,
sourced first by global.R.

## 10. TCGA special-casing: discovery in three places, legacy fallbacks (M) — deferred, decision pending
Go main.go:57/86-101 (`-tcga` flag), dataset_registry.R:164-180, sql_tests.R name hack, deploy.sh and
RELEASE.md special cases; introspection fallbacks in R :143-155 and Go :307-311. Proposed: the file
becomes `datasets/TCGA.db` ("every *.db in datasets/ is a dataset; the file name is the name"), order by
a `dataset_meta` key; delete both introspection fallbacks once tcga.db has dataset_meta. Ops change.

## 11. The plot context object (M) — accepted (with the Shiny step)
`dbfile, roles, dataset_label, keep_samples, rules, gg, base_size, base_family, caption, fig_width`
travel separately through app.R:607/683/810, fun_plot1 (lib.R:804), plotter (:257), survival_km (:61),
fun_table1, gitr_memo, backend_t2; the plan would add tte/type_labels/handles as more arguments.
Proposed `ctx = t2_plot_ctx(bundle, keep, rules)`. Also a shared `t2_prepare_vars()` for the input
preparation repeated in survival_km and plotter.

## 12. The plotter's eleven stages share locals and repeat blocks (M) — deferred (CODE-LAYOUT item 3)
"drop non-numeric, warn, fall back" ×4 (lib.R:360-435), aes blocks ×3 (:566-592), summary sprintf,
title words. Proposed stage functions over a `spec` list.

## 13. Survival knowledge is wider than listed (S–M) — accepted; no client fallbacks
lib.R:855, input_validation.R:55, app.R:762-787, Models.swift:198-201, PlotBuilderSurvival.swift:23-25,
"days"/365 ticks in both apps, KM defaults (5 years, 3 groups) in five places. The tte entry reaches
fun_plot1 through the context; Swift `Context.survivalEndpoints` becomes `[TTEVariable]`; the About
note is generated from tte + about.citation. Plan amendment: no derived-pair fallback in clients; only
in Go, and ideally nowhere once every file declares `tte_variables` (req).

## 14. Go: repeated query/scan loops and small helpers (S–M) — accepted where touched
Query/scan shape in ~10 loaders; sample→row map built twice (:417-420, :441-444); local `contains`
vs slices.Contains; handler boilerplate ×3; "present values" set ×2 (sources.go:138-158, 183-197);
`cohort||subtype||lcohort` ×2; hand-rolled PRAGMA column check. Proposed `each()`, `rowIndex()`,
`serveCached()`, `presentValues()`, `isVirtualColumn()`, `hasColumn()`.

## 15. Go: encoders repeat the numeric test and level→code step (S) — accepted
`anyNumeric` vs encodeAny's first loop; `encodeNumAsCat` vs encodeAny's categorical branch; `textOf` vs
encodeAny's text conversion. Proposed generic `encodeLevels[T]` + `cellText()`. Also: one probes blob
(typed superset) instead of two; drop the `typed=1` switch.

## 16. Swift: repeated filtering and level computations (S) — accepted (iOS step)
"levels present among rows" in PlotBuilder.swift:338/402/453/455/482, PlotBuilderSurvival.swift:80,
Filtering.swift:125-131, AppModel.swift:127-133; "not numeric → warn, drop" wording ×6. Proposed
`Column.levelsPresent(in:)`, `groups(rows:)`, `numericOnly(...)`; keyed dictionaries instead of
`first(where:)` lookups per call.

## 17. The schema is stated in four places (M) — deferred until 2–4 land
dataset_contract_check.R (`need`, `req`, tte fields), sql_tests.R table lists, DATASET-CONTRACT.md,
Go structs/keys, Swift structs. Proposed `schema/t2_schema.json` read by the R lib, the check and
sql_tests; the doc table generated from it. Also: the check must share sql_tests.R's result helpers.

## 18. UI choices and limits declared separately from their validation (S) — accepted (Shiny step)
app.R:254/284/294/295 vs input_validation.R:62/70/72/73; T2_LIMITS vs literals in sanitize_t2_input
(:55-61) and app.R:424-430; 100 probes per request in Go, R (:130) and Swift. Proposed `T2_CONTROLS`
(id, choices, default) used by UI and sanitizer; `limits.values_per_request` in /meta.

## 19. TCGA pipeline scripts duplicate each other and t2_views.R (S) — accepted (next TCGA rebuild)
250-cohorts_table.R == 255-cohorts_table.R (byte-identical, only 255 runs); 250-create_views.R pastes
the t2_views.R DDL; tablemaker.R `insert ignore` pair ×5; the sparse upsert at :122-125 = set_t2_sparse.

## 20. Preset definitions by dataset name live in code (S–M) — accepted
default_filters.R:39-81 holds every dataset's presets as R code keyed by name; `.df_clin` (virtual
columns again) and a fourth rules evaluation (:106-107). Proposed: each builder passes its own
definitions to `write_default_filters(con, defs)` (already accepted, :96); `.df_clin` →
t2_add_virtual_cols; one `t2_rules_mask`.

## 21. Bounded caches implemented four times in R (S) — accepted (quick win)
lib.R:33-46, gitr.R:141-151, gitr.R:347-364, t2_api_client.R:28-30/141-145, t2_thanos.R:99-100/145-149.
Proposed `t2_cache(max)` (drop-oldest) in t2_util.R.

## 22. Test harness code repeated across test_*.R (S) — accepted (quick win)
`ok()` in 14 files (only three count failures, so a failing suite can exit 0); `quiet()` ×6;
set1/press/same_set ×2; the source preamble; hard-coded probes with `if (ds == "TCGA")` branches.
Proposed `Testing/t2_test_lib.R`: `ok()` counting + `finish()` non-zero exit, `quiet()`,
`pick_probes(ds)` from default_y and types.example.

## 23. App content that is neither schema nor api (S, optional) — deferred
Figure presets, citation, print/slide defaults, About prose duplicated between R and Swift. Proposed
`app-content.json` read by Shiny and bundled into iOS at build time (not via the service).

## 24. The api client has local duplicates (S) — accepted (Shiny step)
Rules conversion ×2 (t2_api_client.R:246-254), `chr` ×2 (:216, :235). Proposed `t2_as_rules()`, one `chr`.

## 25. The /datasets row is copied by hand from /meta (S) — accepted (in flight)
main.go:280-300 positional `entry{...}` vs buildMeta's map. Proposed one named summary struct embedded in both.

## What should NOT be generalized (reviewer; lead agrees)
Plotting in R and Swift (two implementations by design, guarded by tests); the statistics
(Stats.swift vs survival_prototype.R/marker_ops.R); the hand-written JSON encoders in Go (no-alloc by
design; only the level logic merges); the suffix rule as a naming convention and Go fallback; the
fact model written slightly differently per builder (wrap common steps only; tablemaker stays);
t2_search.R vs Go ranking (10 lines, documented as the same); retry protocols in R and Swift; the
Thanos bridge; T2_LIMITS values (deliberately different on the phone); per-dataset builder specifics;
the faceted vs single-panel survival paths.

## Reviewer's suggested order
Quick wins: 9, 8, 19, 21, 22, 24, 25. Data layer (avoids a fourth/fifth copy): 2, 3, 4, then 17.
Then 7, 14, 15, 16, 13, 6, 5, 11, 12. Item 1 first as a decision, because it determines whether 5, 6,
7 and 13 are done once in Go or three times.
