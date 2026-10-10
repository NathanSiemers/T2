## t2_presets.R
## ============================================================================
## Ready-made sample subsets ("presets") and the parts of a collection offered
## as data sources of their own ("GTEx", "TARGET" within TCGA-TARGET-GTEx).
##
## This is the R mirror of the t2api service (T2Mobile/service/cmd/t2api:
## loadPresets / derivePresets / ensureHemePreset in dataset.go, sources.go),
## for the SQLite path of the app and for RStudio work. THE SERVICE IS THE
## REFERENCE: T2Mobile/service/test_equivalence.R checks that the two produce
## the same presets and sources on every dataset. Change both or neither.
##
## Where the definitions live: in each database. The `default_filters` table
## (written by default_filters.R at build time) holds the presets; dataset_meta
## holds the parts (source_col, sources, source_labels, source_descriptions).
## A database built before the table existed gets the two classic choices
## derived from its role map (exclude non-tumor, exclude heme), so nothing
## is ever hard-coded per dataset here.
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

## the categorical clinical columns and their levels, as the service sees them:
## text columns; the sample-type column has the dataset's declared levels
t2_clin_levels = function(clin, roles) {
  out = list()
  for (n in setdiff(colnames(clin), "sample")) {
    x = clin[[n]]
    if (!is.character(x) && !is.factor(x)) next
    lv = if (identical(n, roles$sampletype_col) && length(roles$sampletype_levels) > 0)
           roles$sampletype_levels else unique(as.character(x[!is.na(x)]))
    if (length(lv)) out[[n]] = lv          # a column with no values is not categorical (sources.go: no levels)
  }
  out
}

## the presets of a database: its default_filters table, or the derived pair.
## `clin` is the raw clinpheno with the virtual columns (t2_add_virtual_cols).
t2_read_presets = function(con, roles, clin) {
  levels = t2_clin_levels(clin, roles)
  presets = list()
  tab = tryCatch(DBI::dbGetQuery(con, "SELECT preset, description, column_name, op, value, on_by_default
                                        FROM default_filters ORDER BY sort_order, rowid"),
                 error = function(e) NULL)
  known = function(col, vals) vals[vals %in% levels[[col]]]
  if (is.null(tab)) {
    ## derived: the classic choices from the role map
    st = roles$sampletype_col
    if (!is.null(st) && !is.na(st) && nzchar(st)) {
      v = known(st, roles$normal_label[!is.na(roles$normal_label)])
      if (length(v))
        presets[[length(presets) + 1]] = list(label = "Exclude non-tumor", description = "Tumor samples only",
                                              default = FALSE, source = "derived",
                                              rules = list(list(column = st, op = "not in", values = v)))
    }
  } else {
    for (i in seq_len(nrow(tab))) {
      col = tab$column_name[i]; op = tolower(trimws(tab$op[i])); val = tab$value[i]; label = tab$preset[i]
      if (is.null(levels[[col]]) || !(op %in% c("in", "not in")) || !(val %in% levels[[col]])) {
        message(sprintf("default_filters row ignored (preset '%s': %s %s '%s')", label, col, op, val)); next
      }
      j = match(label, vapply(presets, `[[`, "", "label"))
      if (is.na(j)) {
        presets[[length(presets) + 1]] = list(label = label, description = if (is.na(tab$description[i])) "" else tab$description[i],
                                              default = FALSE, source = "database", rules = list())
        j = length(presets)
      }
      presets[[j]]$default = presets[[j]]$default || (!is.na(tab$on_by_default[i]) && tab$on_by_default[i] != 0)
      k = which(vapply(presets[[j]]$rules, function(r) r$column == col && r$op == op, NA))
      if (length(k)) presets[[j]]$rules[[k[1]]]$values = c(presets[[j]]$rules[[k[1]]]$values, val)
      else presets[[j]]$rules[[length(presets[[j]]$rules) + 1]] = list(column = col, op = op, values = val)
    }
  }
  ## the heme exclusion belongs to every collection with blood or lymphoid cohorts
  drops_cohorts = any(vapply(presets, function(p) any(vapply(p$rules, function(r) r$column == "cohort" && r$op == "not in", NA)), NA))
  if (!isTRUE(drops_cohorts)) {
    v = known("cohort", roles$heme_values)
    if (length(v))
      presets[[length(presets) + 1]] = list(label = "Exclude tumors of heme origin", description = "Drop blood and lymphoid cohorts",
                                            default = FALSE, source = "derived",
                                            rules = list(list(column = "cohort", op = "not in", values = v)))
  }
  for (j in seq_along(presets)) presets[[j]]$n_samples = sum(t2_rules_mask(clin, presets[[j]]$rules))
  presets
}

## the data sources of a dataset: the whole collection first, then each part
## declared in dataset_meta. `cohort_order`: the cohort values in menu order
## (the cohorts table). Each source: label, description, rules, n_samples,
## cohorts, groups, exclusions, single_level_columns -- as /meta `sources`.
t2_sources = function(clin, roles, presets, cohort_order = character(0), label = "") {
  levels = t2_clin_levels(clin, roles)
  masks = lapply(presets, function(p) t2_rules_mask(clin, p$rules))
  names(masks) = vapply(presets, `[[`, "", "label")
  describe = function(lab, desc, rules) {
    base = t2_rules_mask(clin, rules)
    cohorts = character(0)
    if ("cohort" %in% colnames(clin)) {
      present = unique(as.character(clin$cohort[base & !is.na(clin$cohort)]))
      cohorts = c(cohort_order[cohort_order %in% present], setdiff(levels[["cohort"]][levels[["cohort"]] %in% present], cohort_order))
    }
    excl = names(masks)[vapply(seq_along(presets), function(i) t2_is_exclusion(presets[[i]]) && .t2_narrows(masks[[i]], base), NA)]
    groups = character(0)
    for (i in seq_along(presets)) {
      p = presets[[i]]
      if (t2_is_exclusion(p) || !.t2_narrows(masks[[i]], base)) next
      dup = any(vapply(excl, function(e) all((masks[[i]] == masks[[e]])[base]), NA))
      if (!isTRUE(dup)) groups = c(groups, p$label)
    }
    single = names(levels)[vapply(names(levels), function(n) {
      x = clin[[n]][base]; length(unique(as.character(x[!is.na(x)]))) <= 1 }, NA)]
    list(label = lab, description = desc, rules = rules, n_samples = sum(base),
         cohorts = cohorts, groups = groups, exclusions = excl, single_level_columns = single)
  }
  out = list(describe(label, "", list()))
  sc = roles$source_col
  if (is.null(sc) || is.na(sc) || !nzchar(sc)) return(out)
  if (is.null(levels[[sc]])) { message("source_col '", sc, "' is not a categorical clinical column; no parts offered"); return(out) }
  for (i in seq_along(roles$sources)) {
    lv = roles$sources[i]
    if (!(lv %in% levels[[sc]])) { message("source '", lv, "' is not a value of ", sc, "; skipped"); next }
    lab = if (i <= length(roles$source_labels) && nzchar(roles$source_labels[i])) roles$source_labels[i] else lv
    desc = if (i <= length(roles$source_descriptions)) roles$source_descriptions[i] else ""
    out[[length(out) + 1]] = describe(lab, desc, list(list(column = sc, op = "in", values = lv)))
  }
  out
}

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
