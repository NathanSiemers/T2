library(DBI)
library(dplyr)
gitrdb = 'tcga.db'

## Default (TCGA) role map. Any dataset can pass its own `roles` list to make
## gitr dataset-agnostic; the keys below name which clinpheno columns play the
## roles of cohort / subtype / sample-type and how the nonormal/noheme filters
## should behave. A NULL/NA role column simply disables the corresponding
## synthetic column or filter for that dataset.
gitr_default_roles = list(
  cohort_col        = "tumtype",
  subtype_col       = "Subtype_Selected",
  sampletype_col    = "sample_type",
  normal_label      = "Solid Tissue Normal",
  heme_values       = c("LAML", "THYM", "DLBC"),
  sampletype_levels = c("Primary Tumor", "Recurrent Tumor", "Metastatic",
                        "Additional - New Primary", "Additional Metastatic",
                        "Primary Blood Derived Cancer - Peripheral Blood",
                        "Solid Tissue Normal")
)

## Synthesise the virtual columns (subtype / cohort / lcohort) on a clinpheno
## frame from the dataset's role map, guarded by column presence so datasets
## that lack a role simply don't get the corresponding virtual column.
## Shared by gitr() and the Thanos backend (t2_thanos.R).
t2_add_virtual_cols = function(clin, roles = gitr_default_roles) {
  role_has = function(key) {
    v = roles[[key]]
    !is.null(v) && length(v) == 1 && !is.na(v) && nzchar(v)
  }
  if (role_has('subtype_col') && roles$subtype_col %in% colnames(clin))
    clin$subtype = clin[[roles$subtype_col]]
  if (role_has('cohort_col') && roles$cohort_col %in% colnames(clin)) {
    if ('cohort' %in% colnames(clin)) clin$lcohort = clin$cohort
    clin$cohort = clin[[roles$cohort_col]]
  }
  clin
}

## The sample pre-filters (Exclude Non-tumor / Exclude heme / Cohort) as ONE
## predicate: logical(nrow(df)), TRUE = keep. `df` must carry the RAW role
## columns (before the sample-type column is re-levelled into a factor) plus
## the virtual `cohort` column. Each filter is a no-op when its role column is
## absent for this dataset. gitr() and the Thanos base mask both call this, so
## what the Filter tab shows and what gets plotted can never disagree.
t2_sample_keep = function(df, roles = gitr_default_roles, cohort = 'all',
                          nonormal = FALSE, noheme = FALSE) {
  role_has = function(key) {
    v = roles[[key]]
    !is.null(v) && length(v) == 1 && !is.na(v) && nzchar(v)
  }
  keep = rep(TRUE, nrow(df))
  stc = roles$sampletype_col
  ccol = roles$cohort_col
  ## normal_label may name ONE or SEVERAL "non-tumor" sample-type values
  ## (e.g. TCGA-TARGET-GTEX has Solid Tissue Normal + Normal Tissue + Cell
  ## Line). Use %in% so a single string and a vector both work.
  nl = roles$normal_label
  nl = nl[!is.na(nl)]
  if (isTRUE(nonormal) && role_has('sampletype_col') && stc %in% colnames(df) &&
      length(nl) > 0)
    keep = keep & !(df[[stc]] %in% nl)
  if (isTRUE(noheme) && role_has('cohort_col') && ccol %in% colnames(df) &&
      length(roles$heme_values) > 0)
    keep = keep & !(df[[ccol]] %in% roles$heme_values)
  if (!is.null(cohort) && any(cohort != "all") && 'cohort' %in% colnames(df))
    keep = keep & (df$cohort %in% cohort)
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
## clinical role map (see gitr_default_roles). Together they make gitr work
## against any T2-shaped dataset, not just TCGA.
##
## `keep_samples`: NULL = no restriction; otherwise a character vector of
## sample ids to keep (the Thanos Filter tab's survivors). character(0) means
## "keep nothing". Supplied by the server only, never by the browser.
gitr = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                cohort = 'all', conn = con,
                makefactors = TRUE,
                dbfile = gitrdb,
                roles = gitr_default_roles,
                db = 'tcga',
                dbcat = 'tcgacat',
                keep_samples = NULL) {

  if (is.null(roles)) roles = gitr_default_roles
  role_has = function(key) {
    v = roles[[key]]
    !is.null(v) && length(v) == 1 && !is.na(v) && nzchar(v)
  }

  gitrconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO )
  on.exit(dbDisconnect(gitrconn), add = TRUE)

  ## drop empty / NA markers (e.g. an unset size/color selector arriving as "")
  probes = unique(probes)
  probes = probes[!is.na(probes) & nzchar(probes)]

  clinpheno = collect(tbl(gitrconn, 'clinpheno'))
  clinpheno_cols = colnames(clinpheno)
  ## synthetic columns created by the phenos=TRUE mutate below
  virtual_cols = c('subtype', 'cohort', 'lcohort')

  ## separate probes that are clinpheno columns vs db probes
  ## virtual_cols (subtype, cohort, lcohort) are created by the phenos mutate —
  ## don't look them up in the database or in clinpheno directly
  is_clin = probes %in% clinpheno_cols
  is_virtual = probes %in% virtual_cols
  clin_probes = probes[is_clin & !is_virtual]
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
      ## deduplicate: some categorical types (fmut) can have multiple values per sample
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
  stc = roles$sampletype_col
  keep = t2_sample_keep(out, roles, cohort = cohort, nonormal = nonormal,
                        noheme = noheme)
  if (!is.null(keep_samples)) keep = keep & (out$sample %in% keep_samples)
  if (!all(keep)) out = out[keep, , drop = FALSE]

  ## factor levels for the sample-type role column (if present + declared)
  if (phenos && role_has('sampletype_col') && stc %in% colnames(out) &&
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

  out %>% droplevels %>% data.frame(check.names = FALSE)
}


## gitr() with a small memory of recent results, for callers that redraw the
## same data with different styling (the Publish tab's live preview). The
## served databases are read-only, so a result stays valid; the key still
## includes the file's size and modification time. Shared by all sessions of
## this R process; the most recent few results are kept.
.gitr_memo = new.env(parent = emptyenv())
.gitr_memo$keys = character(0)
gitr_memo = function(probes, ..., dbfile = gitrdb, max_entries = 6) {
  fi = file.info(dbfile)
  key = rlang::hash(list(probes, list(...), normalizePath(dbfile, mustWork = FALSE),
                         fi$size, fi$mtime))
  hit = .gitr_memo[[key]]
  if (!is.null(hit)) return(hit)
  out = gitr(probes, ..., dbfile = dbfile)
  .gitr_memo[[key]] = out
  .gitr_memo$keys = c(.gitr_memo$keys, key)
  if (length(.gitr_memo$keys) > max_entries) {
    drop = head(.gitr_memo$keys, length(.gitr_memo$keys) - max_entries)
    rm(list = drop, envir = .gitr_memo)
    .gitr_memo$keys = setdiff(.gitr_memo$keys, drop)
  }
  out
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
