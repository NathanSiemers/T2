# PUBLISH-UNIFY round checkpoint (branch publish-unify-20261027, stacked on analysis-20261026)

RESTART POINT. The round implements Nathan's 20261026.notes.md: N1 publication export of the
Analysis result (figure + caption + stats .txt), N2 quantize chips on all six Select
selectors with propagation into the Analysis menus, N3 the Appearance tab dissolved into one
shared style panel at the bottom of Plot and Publish (styles FULLY unified - presets write
the shared state; Nathan's explicit choice). Scope: web + iOS. Contract additions land in
T2Mobile/docs/ANALYSIS-SPEC.md (section 2c per-role token table, section 9 caption/.txt
grammar). The approved plan is ~/.claude/plans/our-t2-databases-and-unified-stardust.md.

Owner rules unchanged: production + API frozen (no deploys, no uploads, branch + PR only);
R only in docker; never write to served paths; PR targets analysis-20261026 (stacks on
PR #15 -> PR #14).

## Step status

| # | step | status |
|---|---|---|
| 0 | branch + round doc | DONE (this commit) |
| 1 | spec: 2c token table, section 9 caption/.txt grammar + literal examples | DONE (this commit) |
| 2 | N1 pure layer: styled t2_plot_group_*, t2_analysis_caption/text, filename 3-arg | DONE bf18344 (115/85; spec literals fixed) |
| 3 | N3 UI+server: shared appearance panel, publish slimming, preset->shared, live redraw | DONE 9359efc (server 24) |
| 4 | N3 test rewrite (browser 111-209, fuzz :131) | DONE 1f652ab (+ stale DEMO block fixed) |
| 5 | N1 server: an_snap reactiveVal, pub_what, analysis branch, .txt downloads | DONE dbcbfc1 (analysis 73) |
| 6 | N2 R: chips on all six selectors, per-role sanitizer/plotter token semantics | DONE ef3195f (7 suites green) |
| 7 | N2 propagation: select_picks -> Analysis menus | DONE aa97af1 (analysis 92) |
| 8 | iOS quantize: x/color/facet cuts, virtual column pre-PlotBuilder, Analysis rows | DONE 9308707 (Linux 125, Mac 12 UI) |
| 9 | iOS analysis export: publishSource, analysisFigureScene, AnalysisExport.swift pins | DONE da9360e (+ method-string parity fix) |
| 10 | lead gates + checkpoint + PR | DONE (this commit; see checkpoint) |

## Checkpoints (newest first)

### 2026-10-27: ROUND COMPLETE - all gates green, PR open
- Final gates: app suites green (server 28, analysis 92, thanos 40, survival 24,
  backend 64, multidataset 75, plot_style 31, group_compare 115, figure_export 85,
  sources 30, about_references 21); test_app_browser full suite green incl. the new
  live-restyle step and the repaired DEMO block; test_browser_suite (unchanged,
  also runs on live) ALL PASS; shiny fuzz ALL PASS with the new 6d section
  (hostile tokens in all roles, junk pub_what/chips); Linux swift 125/125;
  Mac ops/test.sh ios 12 UI tests green; scan --quick detector hits UNCHANGED
  (go 14 / r 9 / swift 7, the pre-round review set).
- Two defects found and fixed by the round's own gates:
  (1) spec 9a Wilcoxon/Welch literals were generated on the wrong vector - caught
  by the step-2 agent's STOP rule, fixed against the real xa fixture (W = 30,
  p = 0.145; t = -1.939, df = 17.6, p = 0.0687), verified in R;
  (2) test_app_browser's DEMO dataset-switch block was STALE since hidden-DEMO
  (5848d94) - set_inputs of a non-menu value is dropped by selectize; bisected to
  prove it was never an app regression; the block now opens DEMO by name via the
  selectize API. No logged gate had run that suite since Oct 20.
- Cross-platform parity fix: Swift's categorical method string "Chi-squared" ->
  "Pearson chi-squared" (R parity for the spec-5 CSV and the caption).
- Platform notes for later: iOS allows color/facet cuts on a survival X (web
  refuses tokens there; display-only); no URL-query handler exists for opening a
  hidden dataset ("deliberate link" in the app comment) - add ?dataset= if wanted;
  condition tokens demote silently when pcortype is none.
- Incident note: a mid-round git stash by one agent briefly swept siblings'
  uncommitted work; recovered and verified, no loss.

### 2026-10-26 night: round opened
- Branch publish-unify-20261027 off analysis-20261026 (63cccf0).
- Decisions with Nathan: Appearance tab removed; styles fully unified (presets restyle the
  screen plot too); chips on all six selectors; web + iOS one round.
- Design facts verified: conditioning requires numeric (lib.R:550-556) so y/size/condition
  tokens demote to the source column for the plot; single shared panel in a conditionalPanel
  below the tabset (unique ids, no sync observers); SceneCanvas already draws scene.caption
  so the iOS figure export only sets it.
