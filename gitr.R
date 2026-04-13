library(DBI)
library(dplyr)
gitrdb = 'tcga.db'


## gitr - data retriever function
## Uses dense views (tcgas, tcgacats) which handle sparse data:
##   tested + no value in tcgai = 0 (sparse zero)
##   tested + NULL in tcgai     = NA (genuine missing)
##   not tested                 = NA (sample not in view)
## Uses datatypes table to determine R class for each probe column.
gitr = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                cohort = 'all', conn = con,
                makefactors = TRUE,
                dbfile = gitrdb,
                db = 'tcga',
                dbcat = 'tcgacat') {

  gitrconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO )
  on.exit(dbDisconnect(gitrconn), add = TRUE)

  probes = unique(probes)

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
    probe_sql = paste(sprintf("'%s'", db_probes), collapse = ", ")

    ## try numeric view first
    num_sql = sprintf("SELECT sample, probe, value FROM tcgas WHERE probe IN (%s)", probe_sql)
    cat(num_sql, "\n")
    num_result = dbGetQuery(gitrconn, num_sql)
    cat(nrow(num_result), "rows returned\n")

    ## try categorical view for any probes not found in numeric
    found_probes = unique(num_result$probe)
    missing_probes = setdiff(db_probes, found_probes)

    if (length(missing_probes) > 0) {
      cat_sql = paste(sprintf("'%s'", missing_probes), collapse = ", ")
      ## try dense categorical view first
      cat_query = sprintf("SELECT sample, probe, value FROM tcgacats WHERE probe IN (%s)", cat_sql)
      cat(cat_query, "\n")
      cat_result = dbGetQuery(gitrconn, cat_query)
      cat(nrow(cat_result), "rows returned\n")

      ## for probes not in the dense view, try sparse fallback (direct tcgacati query)
      cat_found = unique(cat_result$probe)
      still_missing = setdiff(missing_probes, cat_found)
      if (length(still_missing) > 0) {
        sparse_sql = paste(sprintf("'%s'", still_missing), collapse = ", ")
        sparse_query = sprintf(
          "SELECT s.sample, p.probe, d.value FROM tcgacati d
           JOIN samples s ON s.key = d.samplekey
           JOIN probes p ON p.key = d.probekey
           WHERE p.probe IN (%s)", sparse_sql)
        cat(sparse_query, "\n")
        sparse_result = dbGetQuery(gitrconn, sparse_query)
        cat(nrow(sparse_result), "rows returned (sparse)\n")
        cat_result = rbind(cat_result, sparse_result)
      }
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

  ## join with full clinpheno if phenos requested
  if (phenos) {
    probe_cols = setdiff(colnames(rout), clinpheno_cols)
    out = clinpheno %>%
      mutate(subtype = Subtype_Selected, lcohort = cohort, cohort = tumtype) %>%
      left_join(rout[, c('sample', probe_cols), drop = FALSE], by = 'sample')
  } else {
    out = rout
  }

  ## filters
  if (nonormal)
    out = out %>% dplyr::filter(sample_type != "Solid Tissue Normal")
  if (noheme)
    out = out %>% dplyr::filter(tumtype != "LAML" & tumtype != "THYM" & tumtype != "DLBC")
  if (!is.null(cohort) && any(cohort != "all"))
    out = out[out$cohort %in% cohort, ]

  ## factor levels for sample_type
  if (phenos) {
    out$sample_type = factor(out$sample_type,
                             levels = c("Primary Tumor", "Recurrent Tumor", "Metastatic",
                                        "Additional - New Primary", "Additional Metastatic",
                                        "Primary Blood Derived Cancer - Peripheral Blood",
                                        "Solid Tissue Normal"))
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
        uq_sql = paste(sprintf("'%s'", unknown), collapse = ", ")
        ns_types = dbGetQuery(gitrconn, sprintf(
          "SELECT pr.probe, pt.type FROM probes pr
           JOIN probe_types pt ON pt.probekey = pr.key
           WHERE pr.probe IN (%s)
           UNION
           SELECT pr.probe, pt.type FROM probes pr
           JOIN probe_types_cat pt ON pt.probekey = pr.key
           WHERE pr.probe IN (%s)", uq_sql, uq_sql))
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
