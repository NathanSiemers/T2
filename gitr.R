library(DBI)
library(dplyr)
gitrdb = 'datasets/TCGA.db'   # the canonical file is a dataset like the others (2026-10-19)
if (!exists("t2_cache")) source('t2_util.R')              # %||%, t2_role(), t2_cache()
if (!exists("t2_rules_mask")) source('t2_presets.R')      # the rule mask (the rules below)
if (!exists("t2_api_on")) t2_api_on = function() FALSE    # t2_api_client.R replaces this when it is loaded

## ---------------------------------------------------------------------------
## T2_LIMITS: how much ONE request may ask for. All of T2's limits, in one place.
##
## A Shiny instance is one single-threaded R process: while it works on one
## browser's request every other visitor of that process waits. So nothing a
## browser can choose may cost more than a few seconds. Each limit is enforced
## on the server before the expensive step (query, pivot, drawing); a request
## beyond one gets a message in the plot area saying which limit, not a plot.
##
## Where the numbers come from (dev container, one BLAS thread, TCGA, a
## 1400 x 700 px plot; a plain scatter draws in 1.2 s, the default box plot in 3 s):
##   panels          a graph costs 0.13 s to draw: 33 (cohort) 4.5 s, 81 (cohort x
##                   sample type) 12 s, 143 (histological_type) 18 s, 863
##                   (TP53.fmut) 112 s. 100 still allows one graph per cohort in
##                   every dataset (TCGA-TARGET-GTEx has 93) at about 13 s.
##   x / y levels    box plots: 126 categories 3 s, 245 5 s, 863 16 s, 2,557 55 s.
##   colour / size   legend keys: 126 2 s, 245 3 s, 863 8 s, 11,081 92 s.
##   multi_y         each probe plotted individually adds every sample again:
##                   5 probes 5 s, 10 probes 9 s, 20 probes 17 s (box plot by cohort).
##   km_panels       a survival graph costs 0.2 s (33 cohorts: 6 s).
##   *_vars          names per selector: bounds the query (0.03-0.09 s and 0.9 MB
##                   per probe), the Thanos prefetch and the pivot.
##   loess_points    geom_smooth(method = "loess") is quadratic: 1,100 points
##                   1.4 s, 11,000 points 10 s and 140 MB.
## ---------------------------------------------------------------------------
T2_LIMITS = list(
  x_vars         = 20,    # probes combined into X
  y_vars         = 20,    # probes combined into Y (median of z-scores)
  multi_y        = 10,    # Y probes when 'Plot Y probes individually' is ticked
  facet_vars     = 3,     # 'Graph for each' variables
  condition_vars = 10,    # 'Remove influences of' variables
  cohorts        = 200,   # cohort names in one request
  panels         = 100,   # graphs in one plot ('Graph for each', x Y probes)
  km_panels      = 60,    # graphs in one survival (Kaplan-Meier) plot
  x_levels       = 300,   # categories of a categorical X
  y_levels       = 300,   # categories of a categorical Y
  colour_levels  = 200,   # categories of a categorical color
  size_levels    = 200,   # categories of a categorical size
  filter_levels  = 200,   # categories above which a Select-tab variable gets no
                          #   Filter-tab panel of its own accord
  backend_fetch  = 64,    # uncached probes the Thanos backend fetches in one call
  loess_points   = 5000   # points above which a loess fit line is drawn as lm
)

## The role map (`roles`) of a dataset names which clinpheno columns play the
## roles of cohort / subtype / sample-type and how the nonormal/noheme filters
## behave; a NULL/NA role column simply disables the corresponding synthetic
## column or filter. There is NO default map: gitr() over a database file reads
## the roles verbatim from that file's dataset_meta (dataset_roles() in
## dataset_registry.R); over the service they come from /meta (t2_api_resolve).
## The object below stays only so that older scripts that mention it fail soft
## (NULL = "look the roles up in the file").
gitr_default_roles = NULL

## Synthesise the virtual columns (subtype / cohort / lcohort) on a clinpheno
## frame from the dataset's role map, guarded by column presence so datasets
## that lack a role simply don't get the corresponding virtual column.
## Shared by gitr() and the Thanos backend (t2_thanos.R).
t2_add_virtual_cols = function(clin, roles) {
  sub_col = t2_role(roles, 'subtype_col'); coh_col = t2_role(roles, 'cohort_col')
  if (!is.null(sub_col) && sub_col %in% colnames(clin))
    clin$subtype = clin[[sub_col]]
  if (!is.null(coh_col) && coh_col %in% colnames(clin)) {
    if ('cohort' %in% colnames(clin)) clin$lcohort = clin$cohort
    clin$cohort = clin[[coh_col]]
  }
  clin
}

## The sample pre-filters as ONE predicate: logical(nrow(df)), TRUE = keep.
##   rules     the data source, the chosen group and the chosen exclusions, as
##             preset rules (t2_presets.R) -- how the app selects samples
##   nonormal  / noheme: the classic flags, kept for scripts and tests
##   cohort    'all' or cohort values
## `df` must carry the RAW role columns (before the sample-type column is
## re-levelled into a factor) plus the virtual `cohort` column. Each filter is
## a no-op when its role column is absent for this dataset. gitr() and the
## Thanos base mask both call this, so what the Filter tab shows and what gets
## plotted can never disagree.
t2_sample_keep = function(df, roles, cohort = 'all',
                          nonormal = FALSE, noheme = FALSE, rules = list()) {
  keep = rep(TRUE, nrow(df))
  stc = t2_role(roles, 'sampletype_col')
  ccol = t2_role(roles, 'cohort_col')
  ## normal_label may name ONE or SEVERAL "non-tumor" sample-type values
  ## (e.g. TCGA-TARGET-GTEX has Solid Tissue Normal + Normal Tissue + Cell
  ## Line). Use %in% so a single string and a vector both work.
  nl = roles$normal_label
  nl = nl[!is.na(nl)]
  if (isTRUE(nonormal) && !is.null(stc) && stc %in% colnames(df) &&
      length(nl) > 0)
    keep = keep & !(df[[stc]] %in% nl)
  if (isTRUE(noheme) && !is.null(ccol) && ccol %in% colnames(df) &&
      length(roles$heme_values) > 0)
    keep = keep & !(df[[ccol]] %in% roles$heme_values)
  if (!is.null(cohort) && any(cohort != "all") && 'cohort' %in% colnames(df))
    keep = keep & (df$cohort %in% cohort)
  if (length(rules)) keep = keep & t2_rules_mask(df, rules)
  keep
}

## gitr - data retriever function
## Uses dense views (tcgas, tcgacats) which handle sparse data:
##   tested + no value in tcgai = 0 (sparse zero)
##   tested + NULL in tcgai     = NA (genuine missing)
##   not tested                 = NA (sample not in view)
## Uses datatypes table to determine R class for each probe column.
##
## `dbfile` selects which dataset db to query; `roles` provides the dataset's
## clinical role map (see dataset_roles). Together they make gitr work
## against any T2-shaped dataset, not just TCGA.
##
## `keep_samples`: NULL = no restriction; otherwise a character vector of
## sample ids to keep (the Thanos Filter tab's survivors). character(0) means
## "keep nothing". Supplied by the server only, never by the browser.
## The clinical table of a database file, read once per process and file version.
## gitr() needs all of it on every call (sample universe, clinical columns,
## filters); reading and typing its ~13,000 x 56 cells was most of the time of a
## one-probe call. Keyed by path + size + modification time, so a replaced file
## is read again; a handful of entries at most (one per dataset file). The cached
## data frame cannot be altered by callers (R copies on modification).
.gitr_clin = t2_cache(8)
gitr_clinpheno = function(conn, dbfile) {
  fi = file.info(dbfile)
  key = paste(normalizePath(dbfile, mustWork = FALSE), fi$size, as.numeric(fi$mtime))
  hit = .gitr_clin$get(key)
  if (!is.null(hit)) return(hit)
  .gitr_clin$put(key, collect(tbl(conn, 'clinpheno')))
}

## The not-detected fill of the numeric probes in `num_result` (sample, probe, value rows of the dense
## view tcgas: one row per sample TESTED for the probe's type, value NA where there is no stored row or a
## stored NULL). The same semantics as the service (dataset.go fetchProbe): for a probe whose type offers
## `fill` in types.fill_options and is stored in full (sparse = 0), a tested sample with NO stored row (a
## stored NULL counts as stored) becomes 0 (zero) or the smallest stored value of the probe among the
## tested samples of the same cohort (floor), the probe's dataset-wide minimum for a cohort with none;
## a probe with no stored value at all stays NA. Untested samples have no row and stay NA.
## `cohort`: named vector sample -> virtual cohort. Returns list(rows, options, fill, filled, tested_n):
## options the union of the fills the probes' types offer (na, zero, floor), filled / tested_n named
## integer vectors of the probes with cells changed (only when a fill was applied).
gitr_fill_numeric = function(conn, num_result, db_probes, fill, cohort) {
  out = list(rows = num_result, options = "na", fill = NULL, filled = integer(0), tested_n = integer(0))
  if (!nrow(num_result) || !("fill_options" %in% dbListFields(conn, "types"))) return(out)
  ty = dbGetQuery(conn, sprintf("SELECT pr.probe, pt.type FROM probes pr JOIN probe_types pt ON pt.probekey = pr.key
                                 WHERE pr.probe IN (%s) ORDER BY pt.rowid", paste(rep('?', length(db_probes)), collapse = ", ")),
                  params = as.list(db_probes))
  ty = ty[!duplicated(ty$probe), , drop = FALSE]
  ty = ty[ty$probe %in% unique(num_result$probe), , drop = FALSE]
  fo = dbGetQuery(conn, "SELECT type, fill_options FROM types")
  offered = lapply(setNames(fo$fill_options, fo$type), function(v)
    if (is.na(v)) "na" else unique(c("na", intersect(c("zero", "floor"), strsplit(v, "|", fixed = TRUE)[[1]]))))
  sp = if ("sparse" %in% dbListTables(conn)) dbGetQuery(conn, "SELECT type, sparse FROM sparse") else data.frame(type = character(0), sparse = integer(0))
  all_opts = unique(unlist(offered[ty$type]))
  out$options = c("na", "zero", "floor")[c("na", "zero", "floor") %in% c("na", all_opts)]
  if (identical(fill, "na")) return(out)
  rows = num_result
  for (i in seq_len(nrow(ty))) {
    p = ty$probe[i]; t = ty$type[i]
    sparse = !identical(as.integer(sp$sparse[match(t, sp$type)]), 0L)       # a type with no row is sparse
    if (sparse || !(fill %in% offered[[t]])) next
    ix = which(rows$probe == p)
    stored = dbGetQuery(conn, "SELECT sa.sample FROM tcgai dat JOIN probes pr ON pr.key = dat.probekey
                               JOIN samples sa ON sa.key = dat.samplekey WHERE pr.probe = ? AND dat.type = ?",
                        params = list(p, t))$sample
    out$fill = fill
    todo = ix[is.na(rows$value[ix]) & !(rows$sample[ix] %in% stored)]          # tested, no stored row
    if (fill == "zero") new = rep(0, length(todo))
    else {
      have = ix[!is.na(rows$value[ix]) & is.finite(rows$value[ix])]
      gmin = if (length(have)) min(rows$value[have]) else NA_real_
      cm = tapply(rows$value[have], as.character(cohort[rows$sample[have]]), min)
      co = as.character(cohort[rows$sample[todo]])
      new = ifelse(!is.na(co) & co %in% names(cm), cm[co], gmin)
      new = unname(as.numeric(new))
    }
    keep = !is.na(new)
    rows$value[todo[keep]] = new[keep]
    if (any(keep)) { out$filled[p] = sum(keep); out$tested_n[p] = length(ix) }
  }
  out$rows = rows
  out
}

gitr = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                cohort = 'all', conn = con,
                makefactors = TRUE,
                dbfile = gitrdb,
                roles = NULL,
                db = 'tcga',
                dbcat = 'tcgacat',
                keep_samples = NULL,
                rules = list(),
                fill = "na") {      # not-detected values: "na" (missing), "zero" or "floor" (gitr_fill_numeric)

  if (t2_api_on())   # the service is the data layer (t2_api_client.R); dbfile = dataset name
    return(gitr_api(probes, phenos = phenos, nonormal = nonormal, noheme = noheme, cohort = cohort,
                    makefactors = makefactors, dbfile = dbfile, roles = roles,
                    keep_samples = keep_samples, rules = rules, fill = fill))
  if (is.null(roles)) {          # the file's own dataset_meta, verbatim (dataset_registry.R: the file library)
    if (!exists("dataset_roles")) source('dataset_registry.R')
    roles = dataset_roles(dbfile)
  }

  gitrconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO )
  on.exit(dbDisconnect(gitrconn), add = TRUE)

  ## drop empty / NA markers (e.g. an unset size/color selector arriving as "")
  probes = unique(probes)
  probes = probes[!is.na(probes) & nzchar(probes)]
  fl = list(options = "na", fill = NULL)          # replaced when there are database probes

  clinpheno = gitr_clinpheno(gitrconn, dbfile)
  clinpheno_cols = colnames(clinpheno)
  ## synthetic columns created by the phenos=TRUE mutate below
  virtual_cols = c('subtype', 'cohort', 'lcohort')

  ## separate probes that are clinpheno columns vs db probes
  ## virtual_cols (subtype, cohort, lcohort) are created by the phenos mutate —
  ## don't look them up in the database or in clinpheno directly
  is_clin = probes %in% clinpheno_cols
  is_virtual = probes %in% virtual_cols
  ## 'sample' is the key column, always returned: asking for it again must not
  ## select it twice (the join below would stop)
  clin_probes = setdiff(probes[is_clin & !is_virtual], 'sample')
  db_probes = unique(probes[!is_clin & !is_virtual])

  ## start with clinpheno sample list
  rout = clinpheno[, 'sample', drop = FALSE]

  ## fetch clinpheno columns directly
  if (length(clin_probes) > 0) {
    rout = clinpheno[, c('sample', clin_probes), drop = FALSE]
  }

  ## fetch db probes in a single query using the dense views
  if (length(db_probes) > 0) {
    ## bound parameters, never pasted into the SQL text
    in_list = function(n) paste(rep('?', n), collapse = ", ")

    ## try numeric view first
    num_sql = sprintf("SELECT sample, probe, value FROM tcgas WHERE probe IN (%s)", in_list(length(db_probes)))
    num_result = dbGetQuery(gitrconn, num_sql, params = as.list(db_probes))
    cat(nrow(num_result), "rows returned\n")
    ## not-detected values: the fill, and what the answer would say about it (attributes at the end)
    fill = if (fill %in% c("zero", "floor")) fill else "na"
    fl = gitr_fill_numeric(gitrconn, num_result, db_probes, fill,
                           setNames(t2_add_virtual_cols(clinpheno, roles)$cohort %||% rep(NA, nrow(clinpheno)), clinpheno$sample))
    num_result = fl$rows

    ## try categorical view for any probes not found in numeric
    found_probes = unique(num_result$probe)
    missing_probes = setdiff(db_probes, found_probes)

    if (length(missing_probes) > 0) {
      cat_query = sprintf("SELECT sample, probe, value FROM tcgacats WHERE probe IN (%s)", in_list(length(missing_probes)))
      cat_result = dbGetQuery(gitrconn, cat_query, params = as.list(missing_probes))
      cat(nrow(cat_result), "rows returned\n")
    } else {
      cat_result = data.frame(sample = character(0), probe = character(0),
                              value = character(0))
    }

    ## pivot to wide and join
    if (nrow(num_result) > 0) {
      rout = left_join(rout, tidyr::spread(num_result, probe, value), by = 'sample')
    }
    if (nrow(cat_result) > 0) {
      ## deduplicate: some categorical types (fmut) can have multiple values per
      ## sample (two mutations of one gene). Keep ONE by a rule that does not depend
      ## on the order in which SQLite happens to return the rows (that order follows
      ## the index used, so it changed with the covering index): the smallest value
      ## in byte order, a missing value only when there is no other. The t2api
      ## service (T2Mobile/service, dataset.go) applies the same rule.
      cat_result = cat_result[order(cat_result$sample, cat_result$probe, cat_result$value,
                                    method = "radix", na.last = TRUE), , drop = FALSE]
      cat_result = cat_result %>% distinct(sample, probe, .keep_all = TRUE)
      rout = left_join(rout, tidyr::spread(cat_result, probe, value), by = 'sample')
    }

    ## any probes not found at all get an NA column
    for (p in setdiff(db_probes, c(found_probes, unique(cat_result$probe)))) {
      rout[[p]] = NA
    }
  }

  ## join with full clinpheno if phenos requested.
  ## Synthesise the virtual columns (subtype / cohort / lcohort) from the
  ## dataset's role map, guarded by column presence so non-TCGA datasets that
  ## lack these columns simply don't get the corresponding virtual column.
  if (phenos) {
    probe_cols = setdiff(colnames(rout), clinpheno_cols)
    out = t2_add_virtual_cols(clinpheno, roles) %>%
      left_join(rout[, c('sample', probe_cols), drop = FALSE], by = 'sample')
  } else {
    out = rout
  }

  ## filters — each is a no-op when its role column is absent for this dataset
  stc = t2_role(roles, 'sampletype_col')
  keep = t2_sample_keep(out, roles, cohort = cohort, nonormal = nonormal,
                        noheme = noheme, rules = rules)
  if (!is.null(keep_samples)) keep = keep & (out$sample %in% keep_samples)
  if (!all(keep)) out = out[keep, , drop = FALSE]

  ## factor levels for the sample-type role column (if present + declared)
  if (phenos && !is.null(stc) && stc %in% colnames(out) &&
      !is.null(roles$sampletype_levels)) {
    out[[stc]] = factor(out[[stc]], levels = roles$sampletype_levels)
  }

  ## apply R datatypes from the datatypes table
  if (makefactors && length(db_probes) > 0) {
    dt_map = tryCatch(
      dbGetQuery(gitrconn, "SELECT type, r_datatype FROM datatypes"),
      error = function(e) data.frame(type = character(0), r_datatype = character(0))
    )

    if (nrow(dt_map) > 0) {
      dtype_lookup = setNames(dt_map$r_datatype, dt_map$type)
      probe_cols = intersect(colnames(out), db_probes)

      ## determine datatype for each probe column by suffix or db lookup
      probe_dtypes = sapply(probe_cols, function(p) {
        suffix = sub(".*\\.", "", p)
        if (suffix %in% names(dtype_lookup)) return(dtype_lookup[[suffix]])
        NA_character_
      })

      ## batch lookup for nosuffix probes (rna, tmb, sig, estimate)
      unknown = probe_cols[is.na(probe_dtypes)]
      if (length(unknown) > 0) {
        uq_sql = paste(rep('?', length(unknown)), collapse = ", ")
        ns_types = dbGetQuery(gitrconn, sprintf(
          "SELECT pr.probe, pt.type FROM probes pr
           JOIN probe_types pt ON pt.probekey = pr.key
           WHERE pr.probe IN (%s)
           UNION
           SELECT pr.probe, dat.type FROM probes pr
           JOIN tcgacati dat ON dat.probekey = pr.key
           WHERE pr.probe IN (%s)
           GROUP BY pr.probe, dat.type", uq_sql, uq_sql),
          params = as.list(c(unknown, unknown)))
        for (i in seq_len(nrow(ns_types))) {
          idx = which(probe_cols == ns_types$probe[i])
          if (length(idx) > 0 && ns_types$type[i] %in% names(dtype_lookup)) {
            probe_dtypes[idx] = dtype_lookup[[ns_types$type[i]]]
          }
        }
      }

      ## default anything still unknown to numeric
      probe_dtypes[is.na(probe_dtypes)] = "numeric"

      ## apply factor conversion
      factor_cols = probe_cols[probe_dtypes == "factor"]
      if (length(factor_cols) > 0) {
        out = out %>% mutate(across(all_of(factor_cols), as.factor))
      }

      ## convert clinpheno character columns to factor (preserving existing behavior)
      out = out %>% mutate(across(where(is.character) & !all_of(probe_cols), as.factor))

    } else {
      ## fallback: no datatypes table, use legacy suffix matching
      out = out %>%
        mutate(across(where(is.character), as.factor)) %>%
        mutate(across(ends_with('mut'), as.factor)) %>%
        mutate(across(ends_with('cnc'), as.factor))
    }
  } else if (makefactors) {
    ## no db probes, just convert characters to factors
    out = out %>% mutate(across(where(is.character), as.factor))
  }

  out = out %>% droplevels %>% data.frame(check.names = FALSE)
  ## what the service's values answer says: the fills on offer and what the applied one changed
  attr(out, "fill_options") = fl$options
  if (!is.null(fl$fill)) { attr(out, "fill") = fl$fill; attr(out, "filled") = fl$filled; attr(out, "tested_n") = fl$tested_n }
  out
}


## gitr() with a small memory of recent results, for callers that redraw the
## same data with different styling (the Publish tab's live preview). `ctx` is
## the plot context (t2_plot_ctx in lib.R): the dataset (path = its name over the
## service), its roles, the Filter tab's surviving samples (keep) and the sample
## rules. The served data are read-only, so a result stays valid; the key
## includes the dataset version. Shared by all sessions of this R process; the
## most recent few results are kept.
.gitr_memo = t2_cache(6)
gitr_memo = function(probes, ..., ctx) {
  ver = ctx$version %||% if (t2_api_on()) t2_api_version(ctx$path) else {
    fi = file.info(ctx$path); paste(fi$size, as.numeric(fi$mtime)) }
  key = rlang::hash(list(probes, list(...), ctx$path, ver, ctx$roles, ctx$keep, ctx$rules, ctx$fill))
  hit = .gitr_memo$get(key)
  if (!is.null(hit)) return(hit)
  .gitr_memo$put(key, gitr(probes, ..., dbfile = ctx$path, roles = ctx$roles,
                           keep_samples = ctx$keep, rules = ctx$rules, fill = ctx$fill %||% "na"))
}

test_gitr = function(n, phenos = TRUE){
  testconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = gitrdb, flags = RSQLite::SQLITE_RO )
  allprobes = tbl(testconn, 'allprobes')
  sampled = allprobes %>% pull(probe) %>% sample(n)
  time1 = Sys.time()
  out = gitr(sampled, phenos = phenos)
  time2 = Sys.time()
  print(head(out,1))
  print(time1)
  print(time2)
  dbDisconnect(testconn)
}
