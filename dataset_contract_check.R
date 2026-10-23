## dataset_contract_check.R
## ============================================================================
## The conformance check of the T2 dataset contract (T2Mobile/docs/DATASET-CONTRACT.md,
## section 4) for ANY T2 dataset file. Every builder runs it last; sql_tests.R runs it as part
## of run_sql_tests(); a file that fails it is not released.
##
##   Rscript dataset_contract_check.R [--quick] <db> <name>   (exit status 1 on any FAIL; --quick = deep FALSE)
##   source("dataset_contract_check.R"); check_dataset_contract(con, "cptac")
##
## check_dataset_contract(con, name, verbose = TRUE, deep = TRUE) returns invisible(list(results, ok)),
## `results` a data.frame(group, test, status, detail) with status PASS|FAIL|WARN, and prints
## one line per check in the format of sql_tests.R when verbose. A missing dataset_meta table
## or a missing required key is a FAIL, never an error.
## deep = TRUE (the builders, via t2_finalize_dataset) also scans every row of tcgai / tcgacati for
## NULL keys, orphan keys / types and (tcgai) duplicate facts: one pass over the table each, minutes
## on TCGA.db (195 M rows). deep = FALSE (dataset_meta.R after a write, `--quick`) skips those
## scans and runs every check on the small tables (samples, probes, clinpheno, tested, allprobes,
## datatypes, types, dataset_meta and what it references).
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

check_dataset_contract <- function(con, name = "", verbose = TRUE, deep = TRUE) {
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

  add("contract", "types.fill_options (optional): valid, only on sparse = 0 types", function() {
    if (!"types" %in% tabs || !"fill_options" %in% DBI::dbListFields(con, "types")) return(P("no fill_options column: every type offers na only"))
    t <- DBI::dbGetQuery(con, "SELECT type, fill_options FROM types WHERE fill_options IS NOT NULL AND fill_options <> ''")
    if (!nrow(t)) return(P("no type offers a fill"))
    sp <- if ("sparse" %in% tabs) DBI::dbGetQuery(con, "SELECT type, sparse FROM sparse") else data.frame(type = character(0), sparse = integer(0))
    bad <- character(0)
    for (i in seq_len(nrow(t))) {
      r <- tryCatch(t2_fill_options_check(t$fill_options[i]), error = function(e) conditionMessage(e))
      if (!identical(r, t$fill_options[i])) { bad <- c(bad, sprintf("%s: %s", t$type[i], if (identical(r, "na") || is.character(r) && grepl("^[a-z|]+$", r)) "not canonical" else r)); next }
      if (!identical(r, "na") && !identical(as.integer(sp$sparse[match(t$type[i], sp$type)]), 0L)) bad <- c(bad, sprintf("%s offers a fill but is not sparse = 0", t$type[i]))
    }
    if (length(bad)) F(paste(bad, collapse = "; ")) else P(paste(sprintf("%s=%s", t$type, t$fill_options), collapse = ", "))
  })

  ## ---- dataset_meta ----------------------------------------------------------
  meta <- list()
  if (has("dataset_meta") && all(c("key", "value") %in% cols("dataset_meta"))) {
    m <- DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta")
    meta <- setNames(as.list(m$value), m$key)
  }
  getm <- function(k) { v <- meta[[k]]; if (is.null(v) || is.na(v)) "" else as.character(v) }
  levels_of <- function(col) if (nzchar(col) && col %in% clin)
    as.character(DBI::dbGetQuery(con, sprintf("SELECT DISTINCT %s AS v FROM clinpheno WHERE %s IS NOT NULL", qi(col), qi(col)))$v) else NULL
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
  add("contract", "hidden (optional) is 0/1/true/false/yes/no", function() {
    ## the service's metaTrue accepts 1/true/yes (any case); everything else is "listed". The check
    ## accepts the same words and their opposites, so a value that merely looks like a typo is a FAIL
    h <- meta[["hidden"]]
    if (is.null(h)) P("not set")
    else if (tolower(trimws(h)) %in% c("0", "1", "true", "false", "yes", "no")) P(h)
    else F(sprintf("hidden '%s' is not one of 0, 1, true, false, yes, no", h))
  })
  add("contract", "lists are |-separated (not comma-only)", function() {
    ## a value of a level-list key with a comma and no "|" is a comma-separated list, unless the
    ## whole value is itself a level of its column (levels such as "Acute Myeloid Leukemia, Induction ...")
    lk <- c(default_cohorts = "cohort_col", heme_values = "cohort_col", sampletype_levels = "sampletype_col",
            normal_label = "sampletype_col", sources = "source_col")
    bad <- character(0)
    for (k in names(lk)) {
      v <- getm(k)
      if (!grepl(",", v, fixed = TRUE) || grepl("|", v, fixed = TRUE)) next
      cc <- getm(lk[[k]])
      if (!v %in% levels_of(cc)) bad <- c(bad, k)
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
    else { vals <- vapply(rc, getm, ""); P(paste(sprintf("%s=%s", rc[nzchar(vals)], vals[nzchar(vals)]), collapse = " ")) }
  })
  add("contract", "default_cohorts are cohort levels", function() {
    dc <- splitl(getm("default_cohorts"))
    if (!length(dc)) return(P("none declared"))
    cc <- getm("cohort_col")
    if (!nzchar(cc) || !cc %in% clin) return(F("default_cohorts set but cohort_col is not a clinpheno column"))
    bad <- setdiff(dc, levels_of(cc))
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
      f <- T2_TTE_FIELDS
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

  ## ---- references (optional bibliography) ------------------------------------
  refs <- NULL; refs_err <- NULL
  if ("references" %in% names(meta)) {
    refs <- tryCatch({
      rv <- getm("references")
      if (!isTRUE(jsonlite::validate(rv))) stop("not valid JSON")
      t2_references_check(jsonlite::fromJSON(rv, simplifyVector = FALSE))
    }, error = function(e) { refs_err <<- conditionMessage(e); NULL })
  }
  add("contract", "references (optional): parses, records well-formed", function() {
    if (!"references" %in% names(meta)) P("not set")
    else if (!is.null(refs_err)) F(refs_err) else P(sprintf("%d record(s)", length(refs)))
  })
  add("contract", "references: present (non-DEMO datasets)", function() {
    if (identical(toupper(name), "DEMO") || "references" %in% names(meta)) P() else W("no references key (a bibliography is expected)")
  })
  add("contract", "types.reference PMIDs are in references", function() {
    if (!has("types") || !"reference" %in% cols("types")) return(P("no types.reference"))
    tr <- DBI::dbGetQuery(con, "SELECT type, reference FROM types WHERE reference IS NOT NULL")
    if (!nrow(tr)) return(P("no references on types"))
    have <- vapply(refs, function(r) trimws(as.character(r$pmid %||% "")), "")
    ids <- unique(sub("^PMID:?\\s*", "", unlist(regmatches(tr$reference, gregexpr("PMID:?\\s*[0-9]+", tr$reference, perl = TRUE)))))
    if (!length(ids)) return(P("no PMID in types.reference"))
    miss <- setdiff(ids, have)
    if (length(miss)) W(paste("PMID in types.reference with no references record:", paste(miss, collapse = ", "))) else P(sprintf("%d PMID(s)", length(ids)))
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
    if (!deep) return(P(sprintf("%d numeric probes (categorical probes not scanned: deep = FALSE)", nrow(p))))
    cat_multi <- DBI::dbGetQuery(con, "SELECT probekey FROM (SELECT DISTINCT probekey, type FROM tcgacati) GROUP BY probekey HAVING COUNT(*) > 1 LIMIT 5")$probekey
    if (length(cat_multi)) return(F(sprintf("categorical probekeys with several types, e.g. %s", paste(cat_multi, collapse = ","))))
    both <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM (SELECT DISTINCT probekey FROM tcgacati) c JOIN probe_types pt ON pt.probekey = c.probekey")$n
    if (both > 0) F(sprintf("%d probes are both numeric and categorical", both)) else P(sprintf("%d numeric probes", nrow(p)))
  })

  ## ---- keys, duplicates, orphans, references (the small tables: always) -------
  cnt <- function(sql) as.numeric(q1(sql))
  have_cols <- function(t, cc) has(t) && all(cc %in% cols(t))
  add("integrity", "keys unique and non-NULL (small tables)", function() {
    spec <- list(samples = list("key", "sample"), probes = list("key", "probe"), clinpheno = list("sample"),
                 types = list("type"), datatypes = list("type"), allprobes = list("probe"),
                 tested = list(c("sample", "type")))
    bad <- character(0)
    for (t in names(spec)) for (cc in spec[[t]]) {
      if (!have_cols(t, cc)) next        # the schema check says so
      nn <- cnt(sprintf("SELECT COUNT(*) FROM %s WHERE %s", qi(t), paste(sprintf("%s IS NULL", qi(cc)), collapse = " OR ")))
      dd <- cnt(sprintf("SELECT COUNT(*) FROM (SELECT 1 FROM %s GROUP BY %s HAVING COUNT(*) > 1)", qi(t), paste(qi(cc), collapse = ", ")))
      if (nn > 0) bad <- c(bad, sprintf("%s.%s: %d NULL row(s)", t, paste(cc, collapse = "+"), nn))
      if (dd > 0) bad <- c(bad, sprintf("%s.%s: %d duplicated key(s)", t, paste(cc, collapse = "+"), dd))
    }
    if (length(bad)) F(paste(bad, collapse = "; ")) else P()
  })
  add("integrity", "tested: sample and type resolve, every value is 1", function() {
    if (!have_cols("tested", c("sample", "value", "type")) || !have_cols("samples", "sample") || !have_cols("types", "type")) return(P("schema check says"))
    os <- cnt("SELECT COUNT(*) FROM (SELECT sample FROM tested EXCEPT SELECT sample FROM samples)")
    ot <- cnt("SELECT COUNT(*) FROM (SELECT type FROM tested EXCEPT SELECT type FROM types)")
    nv <- cnt("SELECT COUNT(*) FROM tested WHERE value IS NULL OR value <> 1")   # the views ignore the column
    bad <- c(if (os > 0) sprintf("%d distinct tested.sample value(s) (NULL included) not in samples", os), if (ot > 0) sprintf("%d distinct tested.type value(s) (NULL included) not in types", ot),
             if (nv > 0) sprintf("%d rows whose value is not 1 (the views ignore tested.value; 'not tested' is no row)", nv))
    if (length(bad)) F(paste(bad, collapse = "; ")) else P()
  })
  add("integrity", "probes are in allprobes; probe_types resolve", function() {
    if (!have_cols("probes", c("key", "probe")) || !have_cols("allprobes", "probe")) return(P("schema check says"))
    na <- cnt("SELECT COUNT(*) FROM (SELECT probe FROM probes EXCEPT SELECT probe FROM allprobes)")   # set-based: allprobes may have no index
    bad <- if (na > 0) sprintf("%d probes row(s) absent from allprobes", na) else character(0)
    if (have_cols("probe_types", c("probekey", "type")) && have_cols("types", "type")) {
      np <- cnt("SELECT COUNT(*) FROM (SELECT probekey FROM probe_types EXCEPT SELECT key FROM probes)")
      nt <- cnt("SELECT COUNT(*) FROM (SELECT type FROM probe_types EXCEPT SELECT type FROM types)")
      if (np > 0) bad <- c(bad, sprintf("%d probe_types row(s) whose probekey is NULL or not in probes", np))
      if (nt > 0) bad <- c(bad, sprintf("%d probe_types row(s) whose type is NULL or not in types", nt))
    }
    if (length(bad)) F(paste(bad, collapse = "; ")) else P()
  })
  add("integrity", "every type has a datatypes row", function() {
    if (!have_cols("types", "type") || !have_cols("datatypes", "type")) return(P("schema check says"))
    m <- DBI::dbGetQuery(con, "SELECT y.type FROM types y WHERE NOT EXISTS (SELECT 1 FROM datatypes d WHERE d.type = y.type)")$type
    if (length(m)) F(paste("types without a datatypes row:", paste(m, collapse = ", "))) else P()
  })
  add("integrity", "a type with categorical facts (tcgacati) is declared factor", function() {
    if (!have_cols("datatypes", c("type", "r_datatype")) || !have_cols("tcgacati", "type")) return(P("schema check says"))
    num <- DBI::dbGetQuery(con, "SELECT type FROM datatypes WHERE r_datatype = 'numeric'")$type
    bad <- Filter(function(t) cnt(sprintf("SELECT COUNT(*) FROM (SELECT 1 FROM tcgacati WHERE type = %s LIMIT 1)", ql(t))) > 0, num)
    if (length(bad)) F(paste("declared numeric but stored in tcgacati:", paste(bad, collapse = ", "))) else P()
  })

  ## ---- the roles and defaults against the data ----------------------------------
  coh_col <- getm("cohort_col"); sub_col <- getm("subtype_col")
  virt <- c(if (nzchar(coh_col) && coh_col %in% clin) "cohort", if (nzchar(coh_col) && coh_col %in% clin && "cohort" %in% clin) "lcohort",
            if (nzchar(sub_col) && sub_col %in% clin) "subtype")
  add("contract", "default_x/y/color/size/condition name existing variables", function() {
    if (!has("allprobes")) return(P("no allprobes (schema check says)"))
    bad <- character(0)
    for (k in c("default_x", "default_y", "default_color", "default_size", "default_condition")) for (v in splitl(getm(k))) {
      ok <- v %in% clin || v %in% virt || cnt(sprintf("SELECT COUNT(*) FROM allprobes WHERE probe = %s", ql(v))) > 0
      if (!ok) bad <- c(bad, sprintf("%s=%s", k, v))
    }
    if (length(bad)) F(paste("not a variable of the dataset:", paste(bad, collapse = ", "))) else P()
  })
  add("contract", "sampletype_levels cover every sample type", function() {
    lv <- splitl(getm("sampletype_levels")); act <- levels_of(getm("sampletype_col"))
    if (!length(lv)) return(P("none declared"))
    if (is.null(act)) return(P("no sampletype_col (role check says)"))
    miss <- setdiff(act, lv)
    if (length(miss)) F(paste("values of", getm("sampletype_col"), "not in sampletype_levels:", paste(miss, collapse = ", "))) else P(paste(length(lv), "levels"))
  })
  add("contract", "normal_label / heme_values / sources are real levels", function() {
    bad <- character(0)
    for (pr in list(c("normal_label", "sampletype_col"), c("heme_values", "cohort_col"), c("sources", "source_col"))) {
      v <- splitl(getm(pr[1])); if (!length(v)) next
      act <- levels_of(getm(pr[2]))
      if (is.null(act)) { bad <- c(bad, sprintf("%s set but %s is not a clinpheno column", pr[1], pr[2])); next }
      m <- setdiff(v, act)
      if (length(m)) bad <- c(bad, sprintf("%s: %s not in %s", pr[1], paste(m, collapse = ", "), getm(pr[2])))
    }
    if (length(bad)) F(paste(bad, collapse = "; ")) else P()
  })

  ## ---- the fact tables, row by row (deep only: one pass each) ---------------------
  if (!deep) {
    add("integrity", "tcgai / tcgacati row scans (NULL, orphan, duplicate)", function() SKIP("deep = FALSE"))
  } else {
    add("integrity", "tcgai: no NULL or orphan keys/types, no duplicate fact", function() {
      if (!have_cols("tcgai", c("samplekey", "probekey", "type"))) return(P("schema check says"))
      r <- DBI::dbGetQuery(con, "SELECT COUNT(*) n, COALESCE(SUM(samplekey IS NULL OR probekey IS NULL OR type IS NULL), 0) nul,
          COALESCE(SUM(samplekey IS NOT NULL AND NOT EXISTS (SELECT 1 FROM samples s WHERE s.key = d.samplekey)), 0) os,
          COALESCE(SUM(probekey IS NOT NULL AND NOT EXISTS (SELECT 1 FROM probes p WHERE p.key = d.probekey)), 0) op,
          COALESCE(SUM(type IS NOT NULL AND NOT EXISTS (SELECT 1 FROM types y WHERE y.type = d.type)), 0) ot FROM tcgai d")
      dd <- cnt("SELECT COUNT(*) FROM (SELECT 1 FROM tcgai GROUP BY probekey, type, samplekey HAVING COUNT(*) > 1)")
      bad <- c(if (r$nul > 0) sprintf("%.0f rows with a NULL key/type", r$nul), if (r$os > 0) sprintf("%.0f orphan samplekeys", r$os),
               if (r$op > 0) sprintf("%.0f orphan probekeys", r$op), if (r$ot > 0) sprintf("%.0f unknown types", r$ot),
               if (dd > 0) sprintf("%.0f duplicated (probekey, type, samplekey)", dd))
      if (length(bad)) F(paste(bad, collapse = "; ")) else P(sprintf("%.0f rows", r$n))
    })
    add("integrity", "tcgacati: no NULL or orphan keys/types", function() {
      ## several values per (sample, probe) are legitimate here (two mutations of one gene): no duplicate check
      if (!have_cols("tcgacati", c("samplekey", "probekey", "type"))) return(P("schema check says"))
      r <- DBI::dbGetQuery(con, "SELECT COUNT(*) n, COALESCE(SUM(samplekey IS NULL OR probekey IS NULL OR type IS NULL), 0) nul,
          COALESCE(SUM(samplekey IS NOT NULL AND NOT EXISTS (SELECT 1 FROM samples s WHERE s.key = d.samplekey)), 0) os,
          COALESCE(SUM(probekey IS NOT NULL AND NOT EXISTS (SELECT 1 FROM probes p WHERE p.key = d.probekey)), 0) op,
          COALESCE(SUM(type IS NOT NULL AND NOT EXISTS (SELECT 1 FROM types y WHERE y.type = d.type)), 0) ot FROM tcgacati d")
      bad <- c(if (r$nul > 0) sprintf("%.0f rows with a NULL key/type", r$nul), if (r$os > 0) sprintf("%.0f orphan samplekeys", r$os),
               if (r$op > 0) sprintf("%.0f orphan probekeys", r$op), if (r$ot > 0) sprintf("%.0f unknown types", r$ot))
      if (length(bad)) F(paste(bad, collapse = "; ")) else P(sprintf("%.0f rows", r$n))
    })
  }

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
  quick <- "--quick" %in% a; a <- setdiff(a, "--quick")   # --quick: deep = FALSE (no row scans of tcgai / tcgacati)
  if (length(a) < 1) { cat("usage: Rscript dataset_contract_check.R [--quick] <db-path> [dataset-name]\n"); quit(status = 2) }
  nm <- sub("\\.db$", "", basename(a[1])); if (tolower(nm) == "tcga") nm <- "TCGA"   # tcga.db (legacy) and TCGA.db
  con <- DBI::dbConnect(RSQLite::SQLite(), a[1], flags = RSQLite::SQLITE_RO)
  invisible(DBI::dbExecute(con, "PRAGMA busy_timeout = 60000"))
  out <- check_dataset_contract(con, if (length(a) >= 2) a[2] else nm, deep = !quick)
  DBI::dbDisconnect(con)
  quit(status = if (out$ok) 0 else 1)
}
