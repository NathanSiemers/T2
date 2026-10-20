## t2_presets.R
## ============================================================================
## What the app does with the ready-made sample subsets ("presets") and the
## parts of a collection ("sources", e.g. GTEx within TCGA-TARGET-GTEx) that the
## service delivers in /meta: apply their rules to the clinical frame, and decide
## which groups / exclusions to offer for a source at this moment.
##
## The DERIVATIONS (reading default_filters, deriving the classic choices, the
## sources with their cohorts / groups / exclusions) are the service's alone
## (T2Mobile/service/cmd/t2api: loadPresets, sources.go); the R mirror of them
## was deleted with the file mode of the app (DATASET-CONTRACT.md, 2026-10-19).
##
## Vocabulary (shared with the iPhone app):
##   preset     label + rules; a sample is in it when EVERY rule holds; a rule
##              holds when the sample's value of `column` is (`in`) or is not
##              (`not in`) one of `values`. A missing value is never "in".
##   group      a preset with an `in` rule: alternatives, one at most in use
##   exclusion  a preset whose rules are all `not in`: any number in use
##   source     a part of the collection (its own rules) with what makes sense
##              inside it: the cohorts present, the groups and exclusions that
##              change its samples, the clinical columns with a single value
## ============================================================================

## which rows of `clin` (raw clinpheno + virtual columns) satisfy every rule
t2_rules_mask = function(clin, rules) {
  keep = rep(TRUE, nrow(clin))
  for (r in rules) {
    if (!r$column %in% colnames(clin)) next        # validated before: cannot happen
    hit = clin[[r$column]] %in% r$values
    keep = keep & (if (r$op == "in") hit else !hit)
  }
  keep
}

t2_is_exclusion = function(p) length(p$rules) > 0 && all(vapply(p$rules, function(r) r$op == "not in", NA))

## does the preset keep some, but not all, of base?
.t2_narrows = function(pm, base) { kept = sum(pm & base); kept > 0 && kept < sum(base) }

## pick_appropriate_filter(): what the Select tab offers for a data source at
## this moment -- the ONE place that decides which ready-made subsets make
## sense. The groups are the source's; the exclusions are those that still
## change the samples of the source AND the chosen group (within "Primary
## tumors only", "Tumor samples only" removes nothing and is not offered).
## Mirrors AppModel.groupChoices / exclusionChoices in the iPhone app.
##   source   one entry of t2_sources()
##   presets  t2_read_presets() of the same dataset
##   clin     the raw clinpheno + virtual columns the two were computed from
##   group    the label of the group in use, if any
## Returns list(groups = <labels>, exclusions = <labels>, base = <logical mask
## of the source and group>).
t2_filter_choices = function(source, presets, clin, group = NULL) {
  by_label = stats::setNames(presets, vapply(presets, `[[`, "", "label"))
  base = t2_rules_mask(clin, source$rules)
  if (!is.null(group) && group %in% source$groups) base = base & t2_rules_mask(clin, by_label[[group]]$rules)
  excl = source$exclusions[vapply(source$exclusions, function(e) .t2_narrows(t2_rules_mask(clin, by_label[[e]]$rules), base), NA)]
  list(groups = source$groups, exclusions = as.character(excl), base = base)
}

## the samples in use: the source, the chosen group and the chosen exclusions,
## as one logical mask over clin (what t2_sample_keep() applies)
t2_presets_mask = function(source, presets, clin, group = NULL, exclusions = character(0)) {
  ch = t2_filter_choices(source, presets, clin, group)
  by_label = stats::setNames(presets, vapply(presets, `[[`, "", "label"))
  keep = ch$base
  for (e in intersect(exclusions, ch$exclusions)) keep = keep & t2_rules_mask(clin, by_label[[e]]$rules)
  keep
}
