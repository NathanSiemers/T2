# Code-simplification round, 2026-10-23 (branch round-20261020)

Nathan: "run a code simplification scan across the repository - see if the code can be cleaner while still
producing identical results. after the suggested changes, test with any script you have previously used
(security, functionality, weaknesses, etc) to make sure the cleaner has not introduced any bugs."

Four read-only surveys (R app, R data layer, Go, Swift) proposed behavior-preserving cleanups ranked by safety.
The lead applies only the ACCEPTED set below (clearly identical output, test-covered, NOT on the slow TCGA build
path). Everything else is in "Deferred" for a future dedicated rebuild round. Invariant: identical results; verified
by the full suite + security/scan.sh. Posture: conservative (app in Apple review, production frozen).

## ACCEPTED - Go service (cmd/t2api); verify: ops/test.sh go + devstack g4 (equiv, app-service, fuzz-api, abuse)
Apply, all provably identical and covered by the *_test.go + devstack suites:
- A1 delete the unused method `Dataset.column` (dataset.go ~1050) and reword the `columnFill` comment.
- A2 usage.go snapshot (~277): set `Since` once in the struct literal, delete the later `v.Since = ...`.
- A4 contact.go (~160): drop `s == "" ||` (net.ParseIP("") is nil already).
- A5 contact.go validEmail: drop the `at > 0 &&` guard (emailPattern requires a local part); keep mail.ParseAddress.
- A6 dataset.go loadTTE (~428): `ok := func(v TTEVariable) bool { return v.Name != "" && d.clinNum[v.EventCol] && d.clinNum[v.TimeCol] }`.
- A7 dataset.go loadClinical (~367): `if _, ok := byName["cohort"]; !ok {` (order holds "cohort" iff byName has it).
- A8 dataset.go loadSparse (~532): `st := sparseType{sparse: !sp.Valid || sp.Int64 == 1, def: def.Float64}` (NullFloat64 zero is 0).
- A9 dataset.go (~605): fix the misplaced `fillOffers`/`fillOptionsOf` comments.
- A10 dataset.go imports: move syscall/time into the stdlib group, blank sqlite import last (cosmetic).
- A11 dataset.go: `func (d *Dataset) sampleRows() map[string]int32` shared by loadSamples and loadTested.
- A13 sources.go (~125): `if d.db != nil { if rows, err := ...; err == nil { ... } }` (remove the empty if-branch).
- A14 sources.go: one cohort loop over `slices.Concat(cohortOrder, d.levels["cohort"])` (use Concat, not append).
- A15 sources.go: `func distinctWithin(col textCol, base []bool) map[string]bool`; SingleLevel := len(...)<=1.
- A16 sources.go (~160): `dup := slices.ContainsFunc(excl, func(e Preset) bool { return sameWithin(...) })`.
- A17 sources.go rulesMask: `want := r.Op == "in"` hoisted, then `m[i] = m[i] && hit == want`.
- A18 dataset.go loadRoles (~269): loop x/y/color/size/condition, then `default_cohorts` via joinCohorts separately.
- A19 dataset.go: `func clinicalTypeName(n string) string` shared by loadClinical and buildTyped.
- A20 main.go handleValues: `if !slices.ContainsFunc(names[:unknownPrefix], d.isKnown) { s.fail(...) }`.
- A21 main.go strictQuery: `clip(slices.Min(bad))` instead of sort+bad[0].
- A22 main.go: `func (s *server) serveStatic(w,r,d,key,body)` for handleMeta/handleClinical/handleProbes(all=1).
- A23 main.go handleProbes: parse `r.URL.Query()` once (qv), reuse; `all` via `qv["all"]` presence + first=="1".
- A25 dataset.go typedHits (~1396): package-level `var sectionNames = [...]string{"handle","probe","clinical"}`.
SKIP: A3 (clientAddr inline - test churn; keep the wrapper), A24 (defensive bounds check - leave), B1-B5 (MEDIUM,
security/concurrency-adjacent), everything in C/D.

## ACCEPTED - R app/plotting; verify: ops/test.sh app, app-service, browser-service, equiv, test_shiny_fuzz
- S1 lib.R (~1023-1083): delete the `if(FALSE){ test_plot1...; ftest...; fun_plot1(input) }` block.
- S2 lib.R (~338-341): delete `interactive_plotter` and its banner comment (no caller).
- S3 survival_prototype.R (~320-324): delete `save_km()` (no caller).
- S4 lib.R (~380-385, ~560, ~611-613): delete the `if(FALSE){#for testing...}` block in plotter and the listed
  commented-out lines (##myargs, ##cat(file=stderr()...), ##list.of.markers, ##x=paste, ##if(nrow...is.factor)).
- S5 lib.R (~951-954): delete the `if(FALSE){ input=list(...) }` block in fun_plot1.
- S6 lib.R (~1018): use `T2_STYLE_ARGS` directly, drop the `numeric_vars = T2_STYLE_ARGS` alias.
- S7 survival_prototype.R t2_quantile_groups: delete the first `if (length(br) < 2) return(NULL)` (the `made < 2`
  guard already covers it).
- S8 input_validation.R `.t2_one`/`.t2_flag`/`.t2_num`: drop the `length(v)==1` tests after `x[1]` (x[1] is always
  length 1; NA when empty). SAME in figure_export.R `one`(~103)/`side`(~109)/`sw`(~137) and plot_style.R
  t2_validate_tweak. Verify test_shiny_fuzz + test_figure_export + test_plot_style.
- S9 lib.R plotter: drop redundant `!is.null(vec) &` in the all_vars/all_aes_vars and the multi_y facet filters.
- S11 survival_prototype.R: fold the two-step `attr(g,"t2summary") <-` into one paste0 (both sites).
- S12 dataset_registry.R (~144): delete `dataset_db_path()`; also delete `list_datasets()`/`default_dataset()`
  ONLY if the fix agent re-confirms grep shows no caller in the main tree, CPTAC/, TCGA/ (the builders' lib comment
  says "exposes list_datasets()": if any builder references it, KEEP it). Update MULTIDATASET.md:80.
- S13 dataset_registry.R/t2_api_client.R/input_validation.R: delete the stray/duplicate/misplaced comments listed
  (the orphan .split_meta comment, redundant parens on sampletype_col, the misplaced cohort comment at
  input_validation.R:11-12).
- S14 app.R (~939) and S15 plot_style.R (~436): move the two misplaced doc comments to the function they describe.
- S17 t2_api_client.R t2_api_meta: `what = sprintf(...); m = t2_api_get(what)` (hoist the string).
SKIP/DEFER: S10 (var_counts vapply rewrite), S16 (header taste), M1-M13, R1-R4 (see Deferred).

## ACCEPTED - R data layer; verify: DEMO rebuild + sqlite_diff, sql_tests, test_contract_check, test_multidataset,
## test_gitr_api, equiv, CPTAC/test_cptac (+ one CPTAC rebuild for the build_cptac items)
- dS1 delete TCGA/250-cohorts_table.R (byte-identical to 255; 00-master runs 255 only). CONFIRMED.
- dS2 delete TCGA/tablemaker.old.R, TCGA/get_copy_of_estimate.R, TCGA/275-create_kaks.R (0 refs). CONFIRMED.
  Do NOT delete TCGA/create_schema.R (5 refs).
- dS3 TCGA/00-master.R (~11): delete the unused `xena.force = FALSE` var (only use is commented out).
- dS10 t2_views.R drop_t2_dataless_probes (~132): the inner `if (ndel > 0)` is always true; drop the ndel var and
  the inner if, keep the allprobes delete. Verify DEMO rebuild + sqlite_diff + test_multidataset.
- dS11 sqlite_diff.R (reporting tool only): delete the no-op gsub (L37; keep behavior byte-identical - do NOT change
  the encoding), delete the unread sa/ob entries (L138-139), simplify the default-verdict if (L208), compute
  `fields` only where used (L213/L253 share one fp_diffs call), drop the redundant sub() on verdict (L283).
- dS12 dataset_contract_check.R: `f <- T2_TTE_FIELDS` (identical vector); compute the role vapply once for the PASS
  message; share `levels_of` for the default_cohorts and lists checks; the `if(!deep)SKIP; if(deep){}` -> if/else.
  Keep check SEMANTICS and all FAIL/PASS/SKIP messages byte-identical. Verify test_contract_check + contract check
  on cptac deep.
- dS13 gitr.R: unconditional `clinpheno[, c('sample', clin_probes), drop=FALSE]` (character(0) gives the same
  frame); hoist one `t2_add_virtual_cols(clinpheno, roles)` used at both sites; delete `test_gitr()` (no caller);
  delete `gitr_default_roles <- NULL` and inline `roles = NULL` at sql_tests.R:54, fixing that message to "no
  roles". Verify test_gitr_api + equiv + sql_tests.
- dS14 dataset_meta.R: one `need_kv(kv, fmt)` helper for the three identical key=value guards (identical error text
  per fmt); drop the unnecessary `perl=TRUE` on the first sub(). Verify test_contract_check.
- dS15 build_demo_dataset.R: delete the probe_types data frame (L133-140) and its dbWriteTable (L188)
  (t2_finalize_dataset rebuilds probe_types from tcgai; the written copy is discarded). Verify a DEMO rebuild into a
  scratch path + sqlite_diff (expect every table identical) + sql_tests + test_multidataset.
- dS4/dS5/dS6/dS7 CPTAC/build_cptac.R: delete the unused `need` line (L173); drop the redundant second `sub("\r$")`
  (L248,L251; head_ids already strips \r - do NOT touch the sub() on fread output); `function(r) r$M[match(ids,...)]`
  (L351); delete the once-only `flush.console()` in `say` (L144). Verify: a CPTAC rebuild into a scratch path +
  CPTAC/test_cptac.R + sqlite_diff against the current datasets/cptac.db (expect identical).
DEFER (TCGA build path, needs a TCGA rebuild to verify byte-identity): dS8/dS9 tablemaker.R (unused `clin` read,
redundant type re-set, allprobe=uprobe), M1 (250-create_views.R dedup), M2 (mysql dead branches - only after Nathan
says MySQL is retired), M3 (gitr GROUP BY), M4/M5.

## ACCEPTED - Swift; verify: ops/test.sh swift (T2Kit, Linux) + a Mac rebuild (T2App) with the UI suite
Target is iOS 17 / Swift 5.0, so do NOT use `count(where:)` (Swift 6 stdlib).
T2Kit (covered by `swift test` on Linux):
- K1 PlotBuilder.swift (~277): `for probe in use {` (delete the enumerate and `_ = p`).
- K2 PlotBuilder.swift dress (~402): fill byCode and slotOf in one `for (k, code) in order.enumerated()`.
- K3 PlotBuilder.swift (~167): compute the colour distinctCount once, then the cap check (categorical only) and the
  `< 2 -> color = nil` check off that one value. Keep the same empty-scene message and order.
- K4 PlotBuilder.swift: `static func distinctCount(codes:rows:)` shared by the axis cap (~161) and the
  `.categorical` case of distinctCount(_:rows:).
- K5 PlotBuilderSurvival.swift (~121,~93): `Array(stride(...))` and `Set(...).sorted()` (drop `.map{$0}`, `Array()`).
- K6 PlotScene.swift (~59): `(x + y + [color,size,facet] + condition).filter{ !$0.isEmpty }.uniqued()`.
- K7 APIClient.swift (~119): `let got = answers.compactMap{ $0 }` used in both places.
- K8 StatsMore.swift: `static let z95 = 1.959963984540054` used at ~142 and ~250.
- K9 FilterCaption.swift (~102): `counts.map{ $0.0.word }.filter{ !$0.isEmpty }.uniqued()`.
- K10 PlotBuilder.swift: `d.groupOf![r]` (~510); `names.filter{ !dropped.contains($0) }` (~306).
T2App (need a Mac rebuild; covered by compile + the UI suite):
- A1 AppModel.swift: delete `addFilterColumn` (~549), `select(dataset:)` (~383), `sourceLabel` (~184) - no callers;
  call `PresetChoices.isExclusion` at ~670 and delete the `static func isExclusion` wrapper (~580). (Re-confirm no
  callers by grep before each delete.)
- A2 AppModel.swift: drop `@discardableResult` on loadValues (~411) (both callers use the result).
- A3 AppModel.swift outageText (~136): `if let e = lastError as? ServiceTooOld { return e.errorDescription ?? "" }`.
- A4 AppModel.swift (~327): `if let preset, fixedPreset == nil { ...\(preset)... }`.
- A5 AppModel.swift (~290,~390): `Set(...).sorted()`.
- A6 AppModel.swift tableColumns (~702): `wanted.filter{ !$0.isEmpty && filter.columns[$0] != nil }.uniqued()`.
- A7 T2App.swift: `variablesHelp` -> `private let` constant (~329); delete the unread `@Environment model` in
  VariablePicker (~82); merge the two identical checkmark branches (~244) into one `if (multiple && chosen.contains)
  || name == current`.
- A8 AboutView.swift (~80): `if let link = webURL(about.url)` (same http/https check already in SourcesView).
- A9 delete unused imports: PublishView.swift `import UIKit`; PlotStyle.swift `import SwiftUI`+`import T2Kit` (restore
  if the build complains). Leave CohortChooser's import.
DEFER: K11/K12 (MEDIUM), A10/A11 (datasetRevision double-increment is cache-key; MEDIUM), A12/A13, and the
Kruskal-Wallis stale reference (finding E: MethodReferences.swift still lists Kruskal-Wallis, removed from plots
2026-10-07; dropping it changes a pinned test count + docs/IOS.md + docs/APPSTORE.md -> a listing fix for after the
freeze, not a cleanup).

## Deferred catalog (not applied this round)
- R app MEDIUM M1-M13 (default-bundle globals, type-word dedup, t2_fill_of branch merge, noheme=FALSE, pub_spec
  preset, unit-table hoist, exists(T2_LIMITS) guard, cond_cols loop, library(rmarkdown/sqldf/ggthemes) removals,
  t2_api_datasets signature, global.R dead a.* vars) and RISKY R1-R4 (plotter dead params, chr helper, resolve-roles
  duplication, plot_btn handlers).
- R data MEDIUM M1-M5 and all TCGA-build-path items (tablemaker, 250-create_views dedup, mysql branches).
- Go MEDIUM B1-B5 (clientIP flatten, limiter day-rollover helper, cache cost() helper, recover reset, classify
  unused param) and the observations in C (descriptions.go specificity bug - a REAL latent bug to look at separately,
  not a cleanup: a dataset-specific description row with an empty Source is overwritten by a later `*` row).
- Note the Go survey's observation C1 (descriptions.go ~42) as a possible latent bug for a separate look, since
  fixing it changes /meta bytes.
- Swift: finding E, MethodReferences.swift still cites Kruskal-Wallis (removed from the plots 2026-10-07). The
  Sources screen names a method the app no longer computes; docs/IOS.md:117 and docs/APPSTORE.md:164 also list it.
  A listing-accuracy fix for after the freeze (changes a pinned test count), NOT a simplification.

## Result (2026-10-23): APPLIED and GREEN
Three commits: Go c181641, Swift d68478e, R d7d5e8e, plus ASCII hygiene 970677a. Final gate on the combined tree
(dev service rebuilt from the current code, `ops/test.sh all`): go ok; equiv 76; app 30/40/19/24/64/81/75/31/21/59
all 0 FAIL; app-service gitr 117; browser-service ALL PASS; fuzz-api 6; abuse 29; fuzz-shiny 15; contact ALL PASS;
swift 99; exit 0. DEMO and CPTAC rebuilds were byte-identical to the served files (sqlite_diff). The deferred
build-path (tablemaker, 250-create_views dedup, mysql branches) and MEDIUM items remain in this catalog for a future
rebuild round.
