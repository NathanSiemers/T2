## dataset_contract_check.R
## ============================================================================
## The conformance check of the T2 dataset contract (T2Mobile/docs/DATASET-CONTRACT.md,
## section 4) for ANY T2 dataset file. Every builder runs it last; sql_tests.R runs it as part
## of run_sql_tests(); a file that fails it is not released.
##
##   Rscript dataset_contract_check.R <db> <name>          (exit status 1 on any FAIL)
##   source("dataset_contract_check.R"); check_dataset_contract(con, "cptac")
##
## check_dataset_contract(con, name, verbose = TRUE) returns invisible(list(results, ok)),
## `results` a data.frame(group, test, status, detail) with status PASS|FAIL|WARN, and prints
## one line per check in the format of sql_tests.R when verbose. A missing dataset_meta table
## or a missing required key is a FAIL, never an error.
## ============================================================================
suppressMessages({ library(DBI); library(RSQLite); library(jsonlite) })

## the PASS/FAIL vocabulary is shared with sql_tests.R (t2_test_helpers.R), the key list with the builders
.dcc_dir <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  cand <- c(get0(".ROOT", ifnotfound = NULL), get0("ROOT", ifnotfound = NULL),
            if (length(fa)) c(dirname(normalizePath(sub("^--file=", "", fa[1]))), dirname(dirname(normalizePath(sub("^--file=", "", fa[1]))))),
            getwd())
  Filter(function(d) file.exists(file.path(d, "t2_build_lib.R")), cand)[1]
})
if (!exists("t2_run_checks")) source(file.path(.dcc_dir, "t2_test_helpers.R"))
if (!exists("T2_META_KEYS"))  { if (!exists("set_t2_sparse")) source(file.path(.dcc_dir, "t2_views.R")); source(file.path(.dcc_dir, "t2_build_lib.R")) }

check_dataset_contract <- function(con, name = "", verbose = TRUE) {
  tabs <- DBI::dbListTables(con)
  has  <- function(t) t %in% tabs
  cols <- function(t) tryCatch(DBI::dbListFields(con, t), error = function(e) character(0))
  q1   <- function(sql) DBI::dbGetQuery(con, sql)[1, 1]
  qi   <- function(x) as.character(DBI::dbQuoteIdentifier(con, x))
  ql   <- function(x) as.character(DBI::dbQuoteLiteral(con, x))
  splitl <- function(x) { x <- x %||% ""; if (!nzchar(x)) character(0) else strsplit(x, "|", fixed = TRUE)[[1]] }
  `%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

  tests <- list()
  add <- function(group, nm, fn) tests[[length(tests) + 1]] <<- list(group = group, name = nm, fn = fn)
  P <- PASS; F <- FAIL; W <- WARN

  ## ---- the schema ------------------------------------------------------------
  need <- list(
    samples = c("key", "sample"), probes = c("key", "probe"), allprobes = "probe",
    types = c("key", "type", "description", "example", "reference", "source_url", "source_file", "label"),
    datatypes = c("type", "r_datatype"), tested = c("sample", "value", "type"),
    tcgai = c("samplekey", "probekey", "type", "value"), tcgacati = c("samplekey", "probekey", "type", "value"),
    probe_types = c("probekey", "type"), clinpheno = "sample", cohorts = c("cohort", "lcohort", "cohortstring"),
    dataset_meta = c("key", "value"))
  add("contract", "required tables and columns", function() {
    bad <- character(0)
    for (t in names(need)) {
      if (!has(t)) { bad <- c(bad, paste0(t, " (missing)")); next }
      m <- setdiff(need[[t]], cols(t))
      if (length(m)) bad <- c(bad, paste0(t, ".", m, collapse = ", "))
    }
    if (length(bad)) F(paste("missing:", paste(bad, collapse = "; "))) else P(paste(length(need), "tables"))
  })
  add("contract", "views tcgas/tcgacats/tcga/tcgacat (+ bytype)", function() {
    m <- setdiff(c("tcgas", "tcgacats", "tcga", "tcgacat"), tabs)
    if (length(m)) F(paste("missing:", paste(m, collapse = ", ")))
    else if (!"bytype" %in% tabs) W("no bytype view (a build older than t2_views.R's bytype; sql_tests skips its checks)")
    else P()
  })
  add("contract", "default_filters and sparse tables", function() {
    m <- setdiff(c("default_filters", "sparse"), tabs)
    if (length(m)) F(paste("missing:", paste(m, collapse = ", "))) else P()
  })

  ## ---- dataset_meta ----------------------------------------------------------
  meta <- list()
  if (has("dataset_meta") && all(c("key", "value") %in% cols("dataset_meta"))) {
    m <- DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta")
    meta <- setNames(as.list(m$value), m$key)
  }
  getm <- function(k) { v <- meta[[k]]; if (is.null(v) || is.na(v)) "" else as.character(v) }
  req <- c("title", "label", "cohort_col", "tte_variables", "about")
  add("contract", "dataset_meta: required keys present", function() {
    if (!has("dataset_meta")) return(F("no dataset_meta table"))
    miss <- setdiff(req, names(meta))
    emp  <- intersect(c("title", "label", "cohort_col", "about"), names(meta)[vapply(names(meta), function(k) !nzchar(getm(k)), logical(1))])
    if (length(miss)) F(paste("missing keys:", paste(miss, collapse = ", ")))
    else if (length(emp)) F(paste("empty keys:", paste(emp, collapse = ", ")))
    else P(paste(length(meta), "keys"))
  })
  add("contract", "dataset_meta: optional prose keys", function() {
    miss <- setdiff(c("citation", "attribution", "about_url"), names(meta))
    if (length(miss)) W(paste("not set:", paste(miss, collapse = ", "))) else P()
  })

  add("contract", "dataset_meta: no unknown keys", function() {
    u <- setdiff(names(meta), T2_META_KEYS)
    if (length(u)) W(paste("not in the contract:", paste(u, collapse = ", "))) else P()
  })
  add("contract", "order (optional) is an integer", function() {
    o <- meta[["order"]]
    if (is.null(o)) P("not set") else if (grepl("^-?[0-9]+$", o)) P(o) else F(sprintf("order '%s' is not an integer", o))
  })
  add("contract", "lists are |-separated (not comma-only)", function() {
    ## a value of a level-list key with a comma and no "|" is a comma-separated list, unless the
    ## whole value is itself a level of its column (levels such as "Acute Myeloid Leukemia, Induction ...")
    lk <- c(default_cohorts = "cohort_col", heme_values = "cohort_col", sampletype_levels = "sampletype_col",
            normal_label = "sampletype_col", sources = "source_col")
    clin0 <- cols("clinpheno"); bad <- character(0)
    for (k in names(lk)) {
      v <- getm(k)
      if (!grepl(",", v, fixed = TRUE) || grepl("|", v, fixed = TRUE)) next
      cc <- getm(lk[[k]])
      lv <- if (nzchar(cc) && cc %in% clin0) DBI::dbGetQuery(con, sprintf("SELECT DISTINCT %s AS v FROM clinpheno", qi(cc)))$v else character(0)
      if (!v %in% as.character(lv)) bad <- c(bad, k)
    }
    if (length(bad)) F(paste("comma-separated, use '|':", paste(bad, collapse = ", "))) else P()
  })

  ## ---- roles against clinpheno ----------------------------------------------
  clin <- cols("clinpheno")
  add("contract", "clinpheno has a sample column", function() if ("sample" %in% clin) P() else F("no sample column"))
  add("contract", "role columns are in clinpheno", function() {
    rc <- c("cohort_col", "subtype_col", "sampletype_col", "source_col")
    bad <- character(0)
    for (k in rc) { v <- getm(k); if (nzchar(v) && !v %in% clin) bad <- c(bad, sprintf("%s=%s", k, v)) }
    if (length(bad)) F(paste("not a clinpheno column:", paste(bad, collapse = ", ")))
    else P(paste(sprintf("%s=%s", rc[nzchar(vapply(rc, getm, ""))], vapply(rc, getm, "")[nzchar(vapply(rc, getm, ""))]), collapse = " "))
  })
  add("contract", "default_cohorts are cohort levels", function() {
    dc <- splitl(getm("default_cohorts"))
    if (!length(dc)) return(P("none declared"))
    cc <- getm("cohort_col")
    if (!nzchar(cc) || !cc %in% clin) return(F("default_cohorts set but cohort_col is not a clinpheno column"))
    lv <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT %s AS v FROM clinpheno WHERE %s IS NOT NULL", qi(cc), qi(cc)))$v
    bad <- setdiff(dc, as.character(lv))
    if (length(bad)) F(paste("not levels of", cc, ":", paste(bad, collapse = ", "))) else P(paste(length(dc), "cohorts"))
  })

  ## ---- tte variables ---------------------------------------------------------
  tte <- NULL; tte_err <- NULL
  if ("tte_variables" %in% names(meta)) {
    tv <- getm("tte_variables")
    tte <- tryCatch({
      if (!isTRUE(jsonlite::validate(tv))) stop("not valid JSON")
      x <- jsonlite::fromJSON(tv, simplifyVector = FALSE)
      if (!is.list(x) || (length(x) && !is.null(names(x)))) stop("not a JSON array of objects")
      x
    }, error = function(e) { tte_err <<- conditionMessage(e); NULL })
  }
  add("contract", "tte_variables parses (JSON array)", function() {
    if (!"tte_variables" %in% names(meta)) F("key missing")
    else if (!is.null(tte_err)) F(tte_err) else P(sprintf("%d variable(s)", length(tte)))
  })
  if (length(tte)) for (v in tte) local({
    v <- v; nm <- v$name %||% "?"
    add("contract", sprintf("tte %s: well-formed", nm), function() {
      f <- c("name", "label", "event_col", "time_col", "time_unit", "description")
      miss <- f[!vapply(f, function(k) is.character(v[[k]]) && length(v[[k]]) == 1 && nzchar(v[[k]]), logical(1))]
      miss <- setdiff(miss, "description")   # description is advisory
      if (length(miss)) F(paste("missing/empty fields:", paste(miss, collapse = ", "))) 
      else if (!identical(v$time_unit, "days")) F(sprintf("time_unit '%s' (v1 accepts days only)", v$time_unit))
      else if (!nzchar(v$description %||% "")) W("no description") else P()
    })
    add("contract", sprintf("tte %s: event/time columns", nm), function() {
      ev <- v$event_col %||% ""; tm <- v$time_col %||% ""
      m <- setdiff(c(ev, tm), clin)
      if (length(m)) return(F(paste("not in clinpheno:", paste(m, collapse = ", "))))
      bad <- list()
      for (cn in c(ev, tm)) {
        n <- q1(sprintf("SELECT COUNT(*) FROM clinpheno WHERE %s IS NOT NULL AND typeof(%s) NOT IN ('integer','real')", qi(cn), qi(cn)))
        if (n > 0) bad[[length(bad) + 1]] <- sprintf("%s: %d non-numeric", cn, n)
      }
      n <- q1(sprintf("SELECT COUNT(*) FROM clinpheno WHERE %s IS NOT NULL AND %s NOT IN (0, 1)", qi(ev), qi(ev)))
      if (n > 0) bad[[length(bad) + 1]] <- sprintf("%s: %d values outside {0,1}", ev, n)
      n <- q1(sprintf("SELECT COUNT(*) FROM clinpheno WHERE %s IS NOT NULL AND %s < 0", qi(tm), qi(tm)))
      if (n > 0) bad[[length(bad) + 1]] <- sprintf("%s: %d negative values", tm, n)
      nz <- q1(sprintf("SELECT COUNT(*) FROM clinpheno WHERE %s = 0", qi(tm)))   # TCGA's CDR has real zero-day times
      nev <- q1(sprintf("SELECT COUNT(*) FROM clinpheno WHERE %s IS NOT NULL AND %s IS NOT NULL", qi(ev), qi(tm)))
      if (length(bad)) F(paste(unlist(bad), collapse = "; ")) else if (nev == 0) F("no sample has both event and time")
      else if (nz > 0) W(sprintf("%d samples with event+time; %d have %s = 0 (contract says > 0)", nev, nz, tm))
      else P(sprintf("%d samples with event+time", nev))
    })
    add("contract", sprintf("tte %s: name offered as a variable", nm), function() {
      if (!has("allprobes")) return(F("no allprobes"))
      if (q1(sprintf("SELECT COUNT(*) FROM allprobes WHERE probe = %s", ql(nm))) > 0) P() else F("name not in allprobes")
    })
  })

  ## ---- types -----------------------------------------------------------------
  add("contract", "types.label non-NULL for every type", function() {
    if (!has("types") || !"label" %in% cols("types")) return(F("types has no label column"))
    n <- q1("SELECT COUNT(*) FROM types WHERE label IS NULL"); nt <- q1("SELECT COUNT(*) FROM types")
    if (n > 0) F(sprintf("%d of %d types have a NULL label", n, nt)) else P(sprintf("%d types", nt))
  })
  add("contract", "datatypes.r_datatype in {numeric, factor}", function() {
    n <- q1("SELECT COUNT(*) FROM datatypes WHERE r_datatype IS NULL OR r_datatype NOT IN ('numeric','factor')")
    if (n > 0) F(sprintf("%d datatypes rows with another r_datatype", n)) else P()
  })
  add("contract", "every datatypes.type is in types", function() {
    m <- DBI::dbGetQuery(con, "SELECT d.type FROM datatypes d LEFT JOIN types t ON t.type = d.type WHERE t.type IS NULL")$type
    if (length(m)) F(paste("not in types:", paste(m, collapse = ", "))) else P()
  })
  add("contract", "one type per probe", function() {
    pt <- DBI::dbGetQuery(con, "SELECT probekey FROM probe_types GROUP BY probekey HAVING COUNT(*) > 1 LIMIT 5")$probekey
    if (length(pt)) return(F(sprintf("numeric probekeys with several types, e.g. %s", paste(pt, collapse = ","))))
    ## a name's suffix type (text after the last dot) must be its type when it is a datatypes type
    dty <- DBI::dbGetQuery(con, "SELECT type FROM datatypes")$type
    p <- DBI::dbGetQuery(con, "SELECT pr.probe, pt.type FROM probes pr JOIN probe_types pt ON pt.probekey = pr.key")
    suf <- ifelse(grepl("\\.", p$probe), sub(".*\\.", "", p$probe), NA_character_)
    wrong <- !is.na(suf) & suf %in% dty & suf != p$type
    if (any(wrong)) return(F(sprintf("%d numeric probes whose suffix type differs from probe_types, e.g. %s", sum(wrong), p$probe[which(wrong)[1]])))
    cat_multi <- DBI::dbGetQuery(con, "SELECT probekey FROM (SELECT DISTINCT probekey, type FROM tcgacati) GROUP BY probekey HAVING COUNT(*) > 1 LIMIT 5")$probekey
    if (length(cat_multi)) return(F(sprintf("categorical probekeys with several types, e.g. %s", paste(cat_multi, collapse = ","))))
    both <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM (SELECT DISTINCT probekey FROM tcgacati) c JOIN probe_types pt ON pt.probekey = c.probekey")$n
    if (both > 0) F(sprintf("%d probes are both numeric and categorical", both)) else P(sprintf("%d numeric probes", nrow(p)))
  })

  ## ---- run -------------------------------------------------------------------
  res <- t2_run_checks(tests)
  if (verbose) t2_print_results(res, sprintf("\n==== dataset contract check (dataset '%s') ====\n", name))
  invisible(list(results = res, ok = !any(res$status == "FAIL")))
}

## ---- CLI ---------------------------------------------------------------------
.contract_direct <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  length(fa) && identical(basename(sub("^--file=", "", fa[1])), "dataset_contract_check.R")
}
if (.contract_direct()) {
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a) < 1) { cat("usage: Rscript dataset_contract_check.R <db-path> [dataset-name]\n"); quit(status = 2) }
  nm <- sub("\\.db$", "", basename(a[1])); if (tolower(nm) == "tcga") nm <- "TCGA"   # tcga.db (legacy) and TCGA.db
  con <- DBI::dbConnect(RSQLite::SQLite(), a[1], flags = RSQLite::SQLITE_RO)
  invisible(DBI::dbExecute(con, "PRAGMA busy_timeout = 60000"))
  out <- check_dataset_contract(con, if (length(a) >= 2) a[2] else nm)
  DBI::dbDisconnect(con)
  quit(status = if (out$ok) 0 else 1)
}
