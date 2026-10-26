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

## 8. Cross-platform fixture

One small fixture dataset (CSV embedded in both test suites) + a pinned table of
(grouping, variable, toggle) -> (statistic, df, p string) generated by an R script that is
pasted as a comment in the Swift test file (StatsMoreTests pattern). Covers: ties, NA-on-V
both include-missing settings, merged quantile cuts, Fisher boundary, min-n drops.
