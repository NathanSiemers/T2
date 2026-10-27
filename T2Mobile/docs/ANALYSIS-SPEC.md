# ANALYSIS-SPEC: group comparison / Analysis panel (web + iOS)

2026-10-26. Owner request (Nathan): the filter creates filter-positive/negative groups to be
compared by a statistical test ("what's unlikely to be the same"); a low-clutter down-arrow
glyph quantizes a continuous variable into 2-4 quantile groups (a derived categorical usable
anywhere); an Analysis panel selects the grouping and the test variable and shows plots and
tables. Binding rules from the owner: (1) MAINTAINED FILTERS - when a filter/quantile
selection is made for the test, all other filtering options are maintained; (2) model mode
(covariates/contrasts) is DESIGN-ONLY this round - round-1 shapes must let it bolt on with
zero signature changes.

Scope round 1: single comparison + clinical screen (BH-FDR); quantize glyph/derived variable;
both platforms; NO service/API change; NO iOS upload (1.0 in App Review).

Every rule below must hold identically in R and Swift. Swift tests pin numbers produced by
the exact R calls named here (R as in the rstudio:2026.03 image; survival as installed there).

## 1. Universe and row space

Row space = the stable sample vector: row i = `backend$samples[i]` (gitr `character(0)`
clinpheno order) in R; the clinical-order sample array (`Mask` index) on iOS.

- `base` = the Select-tab sample choice: cohort + preset group/exclusion rules.
  R: `h$base()` with NULL -> all TRUE and NA -> FALSE (app.R filter_state). iOS: `baseMask`.
- `m` = base AND every active Thanos/Filter-tab filter. R: `h$th$mask()`. iOS: `mask()`.
- The analysis universe U depends on the grouping (section 2) and never widens past `base`.

## 2. Groupings

A grouping yields (assignment over all rows; NA/-1 = in no group, ordered labels, note).
A test then uses listwise complete cases on {group, test variable}.

### 2a. Leave-one-out filter split (default; one per active filter column V)
- U = base AND all active filters EXCEPT V's.
- Selected = U AND (V's own rule, include-missing honored exactly as the filter mask does);
  Excluded = U minus Selected.
- R: `h$th$streams(V, split_range = FALSE, drop_na = FALSE)` (selected/excluded row ids;
  invariant: disjoint, union = U). iOS: `splitMasks(on: V)` built from `mask(excluding: V)`
  AND V's own `ColumnFilter.mask(for:)`.
- NA on V: include-missing ON -> Selected; OFF -> Excluded. Whenever m > 0 samples are NA on
  V, the result note says "Excluded includes m samples missing <V>." (or Selected ... when ON).
- Labels: "Selected", "Excluded" (that order). Grouping display name = the one-line filter
  description (R `t2_describe_filters` entry; iOS per-filter summary) - display only.

### 2b. Whole-filter split
- Offered only when >= 2 filters are active (with exactly one it EQUALS 2a - test invariant).
- U = base. Selected = m. Excluded = base AND NOT m. Labels as 2a; note lists active filters.

### 2c. Quantized continuous variable - token `t2q::<k>::<name>`, k in {2,3,4}
- U = m (ALL current filters maintained).
- Cut points: quantile type 7 at probs 0, 1/k, ..., 1 over complete cases of <name> within U;
  duplicate quantiles merged (fewer groups may result); outer breaks opened to +-Inf;
  intervals right-closed. Exactly `t2_quantile_groups(x[U], k, min_n = 5)`
  (survival_prototype.R) == Swift `quantileGroupsUnique` + `groupLabels(made:)`.
- Cut points are GLOBAL over U - never per facet, never per subgroup.
- Labels by groups actually MADE: 2 -> Low/High; 3 -> Low/Mid/High; else Q1..Qn.
- Refusal: any group under min_n = 5, or < 2 distinct values -> refuse with a plain message.
- NA on <name>: no group. Display label: "<name> (halves|tertiles|quartiles)" for k = 2|3|4.
- Token accepted only when <name> is a served menu name of kind "num". A literal served
  column named like a token would be shadowed for quantization - theoretical, accepted.

**Token roles (PUBLISH-UNIFY round).** Every variable picker accepts a token from its
quantize affordance; what the PLOT does with it depends on the role. The token always
propagates to the Analysis menus (section 9b) regardless of plot meaning.

| role | plot meaning | plot behavior |
|---|---|---|
| x | yes | derived categorical on X (the categorical-x box/count paths); cuts GLOBAL over the plotted complete source-x/y rows, computed once; a refused cut falls back to the source column with the refusal notice |
| color, facet | yes | derived categorical (as shipped in the ANALYSIS round) |
| y | as color (UI-REWORK round) | the plot keeps the SOURCE continuous column on Y. DEFAULT: the groups become the plot's COLOR - the color menu offers and auto-selects the special entry `quanta` (constant T2_COLOR_QUANTA, t2_util.R); with multi-Y also `probe_quanta` (probe x group, ONE k = the first token's, applied to every probe). Cuts GLOBAL over the plotted complete source-x/y rows, from RAW values, BEFORE conditioning/z-score (same window as x/color tokens). Notice when the groups are consumed as color: "<name>: the plot keeps the continuous values; the groups color the plot (and are offered on the Analysis tab)." When the user overrides color with anything else, the token demotes with the ORIGINAL wording below. A refused cut drops the special color with the refusal notice (probe_quanta degrades to plain probe coloring). |
| size, condition | **none** | the plot uses the SOURCE continuous column and queues the notice "<name>: groups have no meaning as <role>; the plot uses the continuous values (the groups are offered on the Analysis tab)." Conditioning is a numeric residualization (lib.R), so a categorical condition is structurally meaningless. UI-REWORK: condition no longer OFFERS a quantize affordance (chip removed; tokens still sanitize and strip/demote for robustness); its picks still propagate to the Analysis menus (default k = 3). |

Survival plots (x = tte): y/size/condition tokens demote with the ORIGINAL wording BEFORE
the existing color/facet guard (survival_km cuts y itself via km_groups; the quanta color
specials are stripped there - survival_km never reads color); the guard's refusal of
color/facet tokens is unchanged. The color specials (`probe`, `quanta`, `probe_quanta`) are
never fetched as markers and never reach Thanos, table downloads or variable descriptions;
those always see the SOURCE column (t2_quant_source), never a token. iOS mirrors x, color,
graph-for-each, and (UI-REWORK step 6, after web gates) the y-cut-as-color default with the
same semantics and notices; its universe for a Select-tab cut = current mask AND finite
source-x AND finite y - the same plotted-complete-rows rule, pinned cross-platform
(watchlist 14/15).

### 2d. Existing categorical variable
- U = m. Group = value within U; NA = no group. Levels = the SERVED level order restricted to
  levels present in U (droplevels); never re-sorted.
- Groups with n < 5 complete cases (for the chosen test variable) are dropped with a note;
  if < 2 groups remain, refuse.

The min-n = 5 floor and the <2-groups refusal apply to ALL groupings after complete cases.

## 3. Test selection

Variable kind from the typed menu (R `b$menu$kind` num/cat; iOS `Column.Data`). Time-to-event
(tte) endpoints are offered from the dataset's tte list and use their event/time columns.

| kind | groups g | means toggle | test | pinned R call |
|---|---|---|---|---|
| num | 2 | off | Wilcoxon rank-sum, tie-corrected normal approx, continuity-corrected, two-sided | `wilcox.test(x ~ grp, exact = FALSE, correct = TRUE)` |
| num | >2 | off | Kruskal-Wallis, tie-corrected, chi-sq df = g-1 | `kruskal.test(x ~ grp)` |
| num | 2 | on | Welch t, two-sided, Welch-Satterthwaite df | `t.test(x ~ grp)` |
| num | >2 | on | Welch one-way ANOVA | `oneway.test(x ~ grp, var.equal = FALSE)` |
| cat | any | ignored | Pearson chi-sq w/o Yates on the g x L table; if 2x2 AND any expected < 5 -> two-sided Fisher exact | `chisq.test(tab, correct = FALSE)`; `fisher.test(tab)` |
| tte | any | ignored | log-rank, df = g-1, follow-up truncated at surv_max_days exactly as survival_km (time > max -> censored at max) | `survdiff(Surv(time, event) ~ grp)` |

Conventions that must match to the digit:
- Ranks: mid-ranks for ties (R `rank()` default == Swift `ranks`).
- Wilcoxon: W = ranksum(group 1) - n1(n1+1)/2, group 1 = FIRST level; var = (n1*n2/12) *
  ((n+1) - sum(t^3-t)/(n*(n-1))); continuity correction 0.5 toward zero on the numerator;
  two-sided normal p. (wilcox.test's own formula; Swift written from it and pinned.)
- Fisher two-sided: sum of hypergeometric probabilities of all same-margin tables with
  probability <= observed * (1 + 1e-7). The 1e-7 relErr MUST be replicated (R's rule).
  Hypergeometric pmf via logGamma.
- Chi-sq expected counts from the complete-case table margins; all-zero rows/cols dropped
  before df.
- Group ORDER defines sign conventions (Wilcoxon W, t sign): served-level order /
  Selected-before-Excluded / ascending quantile order, identical on both platforms.

## 4. Clinical screen

The chosen grouping vs ALL clinical variables + handles (menu section handle/clinical);
probes out of scope. Per variable: complete cases, the section-3 test by kind (means toggle
honored for num), raw p. Excluded as circular: the grouping's own source column (split column
V, or the quantized source). Variables participating in any OTHER active filter are included
but flagged. BH-FDR pinned to `p.adjust(method = "BH")` over the pooled p list (mixed test
families is fine); m = tests that produced a p; refused/NA rows excluded from m, shown
unranked at the bottom. Table ranked by p ascending; picking a row opens that comparison.

## 5. Output shapes (the model-mode seam)

One result =
- groups block: one row per group - `group`, `n`, then by kind: num -> `median`, `q1`, `q3`;
  cat -> long form `group`, `level`, `count`, `prop`; tte -> `n`, `events`,
  `median_survival` ("NR" when not reached).
- test block (tidy, the seam): data frame with columns
  `term, method, statistic, df, p, p_bh, note` - round 1 has exactly one row, term = "group",
  p_bh = NA outside the screen. Model mode will APPEND rows (covariates, contrasts) to this
  same frame; no shape change.
- Every result carries a `method` field; round 1 sanitizers return method = "auto".
- CSV download = header line (grouping name, universe n, maintained filters) + groups block +
  blank line + test block.
- p formatting: R `fmtp` (NA -> "NA"; <=0 -> "< 1e-300"; < 1e-3 -> %.1e; else %.3g). The iOS
  formatter must produce identical strings (shared-vector test). df display: integer for the
  chi-sq family, %.3g for Welch df.

## 6. Model mode (DESIGN-ONLY, deferred)

Later: `response ~ grouping + <=4 covariates` on the same universe (maintained-filters rule
identical); complete cases on all terms, dropped-n reported; droplevels before fit;
rank-deficient fits refused cleanly. num response -> `lm()` treatment contrasts; tte ->
`coxph(..., ties = "efron")`. Readouts: overall adjusted grouping effect = nested
`anova(fit_without_grouping, fit_full)` (== Type II for the single focal term; no car
dependency); tidy coefficient table (estimate, Wald 95% CI, p; HR scale for coxph); pairwise
grouping contrasts vs a user-chosen reference level (relevel + refit), BH across contrasts.
Round-1 seams that make this additive: the grouping object, the tidy test block, the `method`
field, a reserved `uiOutput('analysis_adjust_ui')` slot (NULL in round 1), iOS
`GroupTestResult.test` as an array of term rows and `runAnalysis(method:)` defaulting to
auto. The screen stays nonparametric-only. Swift model port = its own round 2.

## 7. Silent-divergence watchlist (each gets a pinned cross-platform test)

1. Fisher relErr 1e-7 (knife-edge tables).
2. Wilcoxon continuity direction (toward zero) + two-sided assembly.
3. Mid-ranks and both tie corrections (Wilcoxon, KW).
4. Quantile type 7; right-closed cuts; +-Inf outer breaks.
5. Level order -> W and t sign (pin statistic AND p on both platforms).
6. Filter-split NA placement per include-missing (shared fixture).
7. surv_max_days truncation before log-rank (Analysis p == KM plot p for the same grouping).
8. %.3g / %.1e exact strings (shared p vector).
9. BH with NA/refused entries (excluded from m, left NA).
10. One-active-filter: whole-filter split == leave-one-out split.
11. The publication caption string (section 9a): byte-identical on both platforms before
    wrapping (pin whole captions for one num, one cat, one tte example).
12. The stats .txt format (section 9a).
13. Per-role token behavior (section 2c table): x resolves; size/condition demote with the
    pinned notice text; y keeps continuous values with the groups as default color (quanta),
    original demote wording on user override.
14. iOS Select-tab cut universe == web plotted-complete-rows rule (group n's pinned).
15. Quanta coloring parity (UI-REWORK): web and iOS y-cut group labels/sizes identical over
    the same universe; probe_quanta (probe x group, first token's k) web-only unless iOS has
    a multi-probe plot mode. The PERMANENT interaction suite (test_app_interactions.R) runs
    on every future UI round.

## 8. Cross-platform fixture

One small fixture dataset (CSV embedded in both test suites) + a pinned table of
(grouping, variable, toggle) -> (statistic, df, p string) generated by an R script that is
pasted as a comment in the Swift test file (StatsMoreTests pattern). Covers: ties, NA-on-V
both include-missing settings, merged quantile cuts, Fisher boundary, min-n drops.

## 9. Publication export of a comparison (PUBLISH-UNIFY round)

### 9a. The caption and the stats text

The published figure of an Analysis result carries the full story in its caption; a parallel
plain-text export carries the same sentences plus the tidy tables. Both platforms build the
SAME strings (R is the reference; Swift pins literals). Numbers: statistics by `%.4g`
(sprintf), p by fmtp == Stats.pValueString, df integer unless the method starts "Welch"
(then `%.3g`).

Caption sentences, in order, each ending in ".":

1. `Groups (<grouping label>): <L1> n=<n1>, <L2> n=<n2>[, ...]; universe n=<N>.`
   Group n's from the per-group summary (for a categorical variable, n = the sum of that
   group's level counts). Order = the grouping's level order (section 2).
2. `<method>: <statname> = <%.4g>[, df = <df>], p = <fmtp(p)>.`
   statname map (pinned): Wilcoxon rank-sum -> W; Kruskal-Wallis -> chi-squared;
   Welch t-test -> t; Welch ANOVA -> F; Pearson chi-squared -> chi-squared;
   Fisher exact -> NO statistic clause (`Fisher exact: p = <fmtp(p)>.`);
   Log-rank -> chi-squared. Wilcoxon has no df clause.
3. Any notes (grouping note, test note), verbatim, as their own sentences.
4. `Maintained filters: <the an_filters_line text>.` ("none" when no other filter is active.)
5. `Data: <dataset label>.`
6. The citation (T2_CITATION), last, on its own line - subject to the figure's source switch;
   the statistical sentences are subject to the caption switch.

Worked literal examples (generated with R 4.5.3; the pinned fixtures of the Swift suite):

- numeric, 2 groups (the GroupCompareTests `xa` fixture, 9 Selected / 11 Excluded):
  `Groups (Split: cohort): Selected n=9, Excluded n=11; universe n=20.`
  `Wilcoxon rank-sum: W = 30, p = 0.145.`
  means toggle: `Welch t-test: t = -1.939, df = 17.6, p = 0.0687.`
- categorical, 2x3 table rows Low/High, counts a=12,b=30,c=18 / a=25,b=9,c=6:
  `Pearson chi-squared: chi-squared = 18.62, df = 2, p = 9.1e-05.`
- tte (the Gehan 6-MP fixture, treatment/control, no truncation):
  `Log-rank: chi-squared = 16.79, df = 1, p = 4.2e-05.`

The stats .txt export: line 1 `# T2 analysis: <dataset label>, <YYYY-MM-DD>.`; blank line;
the caption sentences (1-5 above, unwrapped, one per line); blank line; the groups block and
the test block exactly as the CSV export's rows but space-aligned (R: format(); the header
words identical to the CSV header), p shown via fmtp in a final display column `p_text`
(and `p_bh_text` for screens). The figure caption is wrapped to the figure width by
t2_caption_text (web); iOS draws it via SceneCanvas at axisTextSize * 0.8 as any caption.

### 9b. Select -> Analysis propagation

The Analysis menus front the user's current Select-tab picks ("from Select" rows) above the
served lists: for each sanitized pick of x/y/color/size/facet/condition - a token (or a
continuous pick, tokenized with that slot's chip k, default 3) becomes a grouping row; its
source column (or a categorical pick) becomes a test-variable row; an x that is a tte
endpoint becomes a test-variable row only. Rows are MOVED to the front with a "- from
Select" label, never duplicated. The menus are advisory: sanitize_t2_analysis remains the
sole gate and is unchanged by this round.

### 9c. Rebuild-from-snapshot rule (web)

The published analysis figure is rebuilt from the stored comparison snapshot (grouping,
groups, test rows, maintained-filters line, dataset) - never re-queried, so it always equals
the tables the user saw. Publishing with a different dataset open is refused with a plain
message. No comparison yet -> the Publish preview explains how to make one.

## 10. Shared appearance state (web only)

One style state (the T2_STYLE ids + show_legend + the tweak set) serves the screen plot and
the published figure; the panel lives below the tab bar on the Plot and Publish tabs. Figure
presets WRITE this shared state when chosen (never on tab entry). Print-only overlays stay
out of it: the preset's base_size and its gg defaults apply only at figure render; plot_height
is screen-only. Style changes redraw the current screen plot (debounced) once a plot exists.
iOS is unaffected (its PlotStyle already serves both the screen and the export).
