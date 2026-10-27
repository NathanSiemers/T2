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
| 1 | spec: 2c token table, section 9 caption/.txt grammar + literal examples | pending |
| 2 | N1 pure layer: styled t2_plot_group_*, t2_analysis_caption/text, filename 3-arg | pending |
| 3 | N3 UI+server: shared appearance panel, publish slimming, preset->shared, live redraw | pending |
| 4 | N3 test rewrite (browser 111-209, fuzz :131) | pending |
| 5 | N1 server: an_snap reactiveVal, pub_what, analysis branch, .txt downloads | pending |
| 6 | N2 R: chips on all six selectors, per-role sanitizer/plotter token semantics | pending |
| 7 | N2 propagation: select_picks -> Analysis menus | pending |
| 8 | iOS quantize: x/color/facet cuts, virtual column pre-PlotBuilder, Analysis rows | pending |
| 9 | iOS analysis export: publishSource, analysisFigureScene, AnalysisExport.swift pins | pending |
| 10 | lead gates + checkpoint + PR | pending |

## Checkpoints (newest first)

### 2026-10-26 night: round opened
- Branch publish-unify-20261027 off analysis-20261026 (63cccf0).
- Decisions with Nathan: Appearance tab removed; styles fully unified (presets restyle the
  screen plot too); chips on all six selectors; web + iOS one round.
- Design facts verified: conditioning requires numeric (lib.R:550-556) so y/size/condition
  tokens demote to the source column for the plot; single shared panel in a conditionalPanel
  below the tabset (unique ids, no sync observers); SceneCanvas already draws scene.caption
  so the iOS figure export only sets it.
