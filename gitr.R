library(DBI)
library(dplyr)
gitrdb = 'tcga.db'


## gitr - data retriever function
## Uses dense views (tcgas, tcgacats) which handle sparse data:
##   tested + no value in tcgai = 0 (sparse zero)
##   tested + NULL in tcgai     = NA (genuine missing)
##   not tested                 = NA (sample not in view)
gitr = function(probes, phenos = TRUE, nonormal = FALSE, noheme = FALSE,
                cohort = 'all', conn = con,
                makefactors = TRUE,
                dbfile = gitrdb,
                db = 'tcga',
                dbcat = 'tcgacat') {

  gitrconn = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO )
  on.exit(dbDisconnect(gitrconn), add = TRUE)

  clinpheno = collect(tbl(gitrconn, 'clinpheno'))
  clinpheno_cols = colnames(clinpheno)

  ## separate probes that are clinpheno columns vs db probes
  is_clin = probes %in% clinpheno_cols
  clin_probes = probes[is_clin]
  db_probes = unique(probes[!is_clin])

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
    num_query = sprintf(
      "SELECT sample, probe, value FROM tcgas WHERE probe IN (%s)", probe_sql)
    num_result = dbGetQuery(gitrconn, num_query)

    ## try categorical view for any probes not found in numeric
    found_probes = unique(num_result$probe)
    missing_probes = setdiff(db_probes, found_probes)

    if (length(missing_probes) > 0) {
      cat_sql = paste(sprintf("'%s'", missing_probes), collapse = ", ")
      cat_query = sprintf(
        "SELECT sample, probe, value FROM tcgacats WHERE probe IN (%s)", cat_sql)
      cat_result = dbGetQuery(gitrconn, cat_query)
      ## categorical values stay as character
    } else {
      cat_result = data.frame(sample = character(0), probe = character(0),
                              value = character(0))
    }

    ## pivot numeric results to wide
    if (nrow(num_result) > 0) {
      num_wide = tidyr::spread(num_result, probe, value)
      rout = left_join(rout, num_wide, by = 'sample')
    }

    ## pivot categorical results to wide
    if (nrow(cat_result) > 0) {
      cat_wide = tidyr::spread(cat_result, probe, value)
      rout = left_join(rout, cat_wide, by = 'sample')
    }

    ## any probes not found at all get an NA column
    still_missing = setdiff(db_probes, c(found_probes, unique(cat_result$probe)))
    for (p in still_missing) {
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
  if (nonormal) {
    out = out %>% dplyr::filter(sample_type != "Solid Tissue Normal")
  }
  if (noheme) {
    out = out %>% dplyr::filter(tumtype != "LAML" & tumtype != "THYM" & tumtype != "DLBC")
  }
  if (!is.null(cohort)) {
    if (any(cohort != "all")) {
      out = out[out$cohort %in% cohort, ]
    }
  }

  ## factor levels for sample_type
  if (phenos) {
    out$sample_type = factor(out$sample_type,
                             levels = c("Primary Tumor",
                                        "Recurrent Tumor",
                                        "Metastatic",
                                        "Additional - New Primary",
                                        "Additional Metastatic",
                                        "Primary Blood Derived Cancer - Peripheral Blood",
                                        "Solid Tissue Normal"))
  }

  ## make factors
  if (makefactors) {
    out = out %>% mutate_if(is.character, as.factor)
    out = out %>% mutate_at(dplyr::vars(ends_with('mut')), ~ as.factor(.))
    out = out %>% mutate_at(dplyr::vars(ends_with('cnc')), ~ as.factor(.))
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
