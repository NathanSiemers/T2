## sql_tests.R
## ============================================================================
## A LARGE, REUSABLE SQL-level test suite for ANY T2-shaped dataset db
## (tcga.db, datasets/DEMO.db, datasets/tcgatargetgtex.db, ...). It checks the
## things the T2 Shiny app, gitr, and a human analyst actually ask for, so a
## newly-built dataset can be validated the same way the canonical one is.
##
## Lives in the PROJECT ROOT so it can be run on any db and sourced by the
## build pipeline (00-master.R runs it on tcga.db at the end of a rebuild).
##
##   Rscript sql_tests.R datasets/tcgatargetgtex.db
##   Rscript sql_tests.R tcga.db TCGA
##   # or from R:  source('sql_tests.R'); run_sql_tests('datasets/DEMO.db')
##
## Design: each check returns list(ok, detail) or "SKIP"; an error counts as
## FAIL (never aborts the run). Add new checks over time by appending to the
## `add(...)` list -- that is the whole point of keeping this around.
## ============================================================================

suppressMessages({ library(DBI); library(RSQLite) })

.this_dir <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(sub("^--file=", "", fa[1]))) else getwd()
}
.ROOT <- .this_dir()
if (!exists("gitr"))         source(file.path(.ROOT, "gitr.R"))
if (!exists("dataset_info")) source(file.path(.ROOT, "dataset_registry.R"))

## ---- small helpers ---------------------------------------------------------
.q1  <- function(con, sql) tryCatch(DBI::dbGetQuery(con, sql)[1, 1], error = function(e) NA)
.qdf <- function(con, sql) DBI::dbGetQuery(con, sql)
.tables <- function(con) DBI::dbListTables(con)
.cols   <- function(con, t) tryCatch(DBI::dbListFields(con, t), error = function(e) character(0))
.has    <- function(con, t) t %in% .tables(con)
PASS <- function(detail = "") list(ok = TRUE,  detail = detail)
FAIL <- function(detail = "") list(ok = FALSE, detail = detail)
SKIP <- function(detail = "") list(ok = NA,    detail = paste("SKIP:", detail))
## WARN: a noted condition that is NOT a failure (e.g. an expected-but-worth-
## flagging data property). Does not affect the overall ok/pass verdict.
WARN <- function(detail = "") list(ok = TRUE, warn = TRUE, detail = detail)

## resolve a role map for an arbitrary db path (reuses the registry resolver)
.roles_for <- function(dbpath, name = NULL) {
  if (is.null(name)) {
    bn <- basename(dbpath)
    name <- if (tolower(bn) == "tcga.db") "TCGA" else sub("\\.db$", "", bn)
  }
  r <- tryCatch(.resolve_roles(name, dbpath),
                error = function(e) list(roles = gitr_default_roles,
                                         defaults = list(), title = name, label = name))
  list(name = name, roles = r$roles, defaults = r$defaults)
}

## ============================================================================
run_sql_tests <- function(dbpath, name = NULL, verbose = TRUE) {
  stopifnot(file.exists(dbpath))
  con <- dbConnect(SQLite(), dbname = dbpath, flags = SQLITE_RO)
  on.exit(dbDisconnect(con), add = TRUE)

  ri    <- .roles_for(dbpath, name)
  roles <- ri$roles
  clin_cols <- .cols(con, "clinpheno")
  role_has  <- function(k) { v <- roles[[k]]; !is.null(v) && length(v) >= 1 && !is.na(v[1]) && nzchar(v[1]) }

  ## pick a numeric "gene" probe (prefer the dataset's default_y), a 2nd gene,
  ## and a categorical probe if one exists
  num_probes <- .qdf(con, "SELECT pr.probe FROM probes pr
                           JOIN probe_types pt ON pt.probekey = pr.key LIMIT 5000")$probe
  dy   <- ri$defaults$default_y
  gene  <- if (!is.null(dy) && nzchar(dy) && dy %in% num_probes) dy else num_probes[1]
  gene2 <- setdiff(num_probes, gene)[1]
  cat_probe <- .q1(con, "SELECT pr.probe FROM probes pr
                         JOIN tcgacati dat ON dat.probekey = pr.key LIMIT 1")
  ccol <- if (role_has("cohort_col")) roles$cohort_col else NA
  stc  <- if (role_has("sampletype_col")) roles$sampletype_col else NA

  gitr_quiet <- function(...) {
    out <- NULL
    suppressWarnings(suppressMessages(capture.output(
      out <- gitr(..., dbfile = dbpath, roles = roles))))
    out
  }

  ## ---- the checks ----------------------------------------------------------
  tests <- list()
  add <- function(group, name, fn) tests[[length(tests) + 1]] <<- list(group = group, name = name, fn = fn)

  ## --- STRUCTURE ---
  add("structure", "core tables exist", function() {
    need <- c("samples","probes","allprobes","types","datatypes","tested",
              "tcgai","tcgacati","probe_types","clinpheno","cohorts")
    miss <- need[!vapply(need, function(t) .has(con, t), logical(1))]
    if (length(miss)) FAIL(paste("missing:", paste(miss, collapse=", "))) else PASS()
  })
  add("structure", "core views exist", function() {
    need <- c("tcgas","tcgacats","tcga","tcgacat")
    miss <- need[!vapply(need, function(t) .has(con, t), logical(1))]
    if (length(miss)) FAIL(paste("missing:", paste(miss, collapse=", "))) else PASS()
  })

  ## --- DIMENSION INTEGRITY ---
  add("dimension", "samples: non-empty + unique sample + unique key", function() {
    n <- .q1(con, "SELECT COUNT(*) FROM samples")
    du <- .q1(con, "SELECT COUNT(*)-COUNT(DISTINCT sample) FROM samples")
    dk <- .q1(con, "SELECT COUNT(*)-COUNT(DISTINCT key) FROM samples")
    if (n == 0) FAIL("no samples") else if (du != 0) FAIL("duplicate sample names")
    else if (dk != 0) FAIL("duplicate keys") else PASS(sprintf("%d samples", n))
  })
  add("dimension", "probes: non-empty + unique probe + unique key", function() {
    n <- .q1(con, "SELECT COUNT(*) FROM probes")
    du <- .q1(con, "SELECT COUNT(*)-COUNT(DISTINCT probe) FROM probes")
    dk <- .q1(con, "SELECT COUNT(*)-COUNT(DISTINCT key) FROM probes")
    if (n == 0) FAIL("no probes") else if (du != 0) FAIL("duplicate probe names")
    else if (dk != 0) FAIL("duplicate keys") else PASS(sprintf("%d probes", n))
  })
  add("dimension", "allprobes superset of probes", function() {
    miss <- .q1(con, "SELECT COUNT(*) FROM probes WHERE probe NOT IN (SELECT probe FROM allprobes)")
    if (miss != 0) FAIL(sprintf("%d probes not in allprobes", miss)) else PASS()
  })

  ## --- REFERENTIAL INTEGRITY ---
  add("referential", "tcgai.samplekey -> samples.key", function() {
    o <- .q1(con, "SELECT COUNT(*) FROM tcgai WHERE samplekey NOT IN (SELECT key FROM samples)")
    if (o != 0) FAIL(sprintf("%d orphan samplekeys", o)) else PASS()
  })
  add("referential", "tcgai.probekey -> probes.key", function() {
    o <- .q1(con, "SELECT COUNT(*) FROM tcgai WHERE probekey NOT IN (SELECT key FROM probes)")
    if (o != 0) FAIL(sprintf("%d orphan probekeys", o)) else PASS()
  })
  add("referential", "tcgai.type -> types.type", function() {
    o <- .q1(con, "SELECT COUNT(*) FROM tcgai WHERE type NOT IN (SELECT type FROM types)")
    if (o != 0) FAIL(sprintf("%d rows with unknown type", o)) else PASS()
  })
  add("referential", "tcgacati keys+type resolve", function() {
    if (.q1(con, "SELECT COUNT(*) FROM tcgacati") == 0) return(SKIP("no categorical data"))
    o <- .q1(con, "SELECT COUNT(*) FROM tcgacati WHERE samplekey NOT IN (SELECT key FROM samples)
                   OR probekey NOT IN (SELECT key FROM probes)
                   OR type NOT IN (SELECT type FROM types)")
    if (o != 0) FAIL(sprintf("%d orphan categorical rows", o)) else PASS()
  })
  add("referential", "tested.sample/type resolve", function() {
    os <- .q1(con, "SELECT COUNT(*) FROM tested WHERE sample NOT IN (SELECT sample FROM samples)")
    ot <- .q1(con, "SELECT COUNT(*) FROM tested WHERE type NOT IN (SELECT type FROM types)")
    if (os != 0) FAIL(sprintf("%d tested rows with unknown sample", os))
    else if (ot != 0) FAIL(sprintf("%d tested rows with unknown type", ot)) else PASS()
  })
  add("referential", "clinpheno.sample is unique", function() {
    du <- .q1(con, "SELECT COUNT(*)-COUNT(DISTINCT sample) FROM clinpheno")
    if (du != 0) FAIL("duplicate clinpheno.sample") else PASS()
  })
  add("referential", "clinpheno covers tested samples", function() {
    ## Samples assayed (in `tested`) but lacking a clinpheno row are dropped by
    ## the clinical `tcga`/`tcgacat` views (they still appear in tcgas/tcgacats).
    ## This is EXPECTED in tcga.db (samples never clinically processed), so it
    ## is a WARN, not a FAIL -- but a large gap in a fresh dataset is worth
    ## seeing.
    miss <- .q1(con, "SELECT COUNT(DISTINCT sample) FROM tested
                      WHERE sample NOT IN (SELECT sample FROM clinpheno)")
    if (miss != 0) WARN(sprintf("%d tested samples not in clinpheno (absent from clinical views by design)", miss))
    else PASS()
  })
  add("referential", "datatypes covers every type", function() {
    miss <- .q1(con, "SELECT COUNT(*) FROM types WHERE type NOT IN (SELECT type FROM datatypes)")
    if (miss != 0) FAIL(sprintf("%d types missing an r_datatype", miss)) else PASS()
  })

  ## --- PROBE_TYPES CORRECTNESS (drives the dense numeric view) ---
  add("probe_types", "probe_types == DISTINCT tcgai(probekey,type)", function() {
    a <- .q1(con, "SELECT COUNT(*) FROM (SELECT DISTINCT probekey,type FROM tcgai
                   EXCEPT SELECT probekey,type FROM probe_types)")
    b <- .q1(con, "SELECT COUNT(*) FROM (SELECT probekey,type FROM probe_types
                   EXCEPT SELECT DISTINCT probekey,type FROM tcgai)")
    if (a != 0 || b != 0) FAIL(sprintf("mismatch (missing=%s extra=%s)", a, b)) else PASS()
  })

  ## --- VIEW SEMANTICS (sparse reconstruction) ---
  add("views", "tcgas dense: row count == tested count for a probe", function() {
    if (is.na(gene)) return(SKIP("no numeric probe"))
    ntested <- .q1(con, sprintf("SELECT COUNT(DISTINCT t.sample) FROM tested t
      JOIN probe_types pt ON pt.type=t.type JOIN probes pr ON pr.key=pt.probekey
      WHERE pr.probe = '%s'", gene))
    nview <- .q1(con, sprintf("SELECT COUNT(*) FROM tcgas WHERE probe='%s'", gene))
    nnull <- .q1(con, sprintf("SELECT COUNT(*) FROM tcgas WHERE probe='%s' AND value IS NULL", gene))
    if (nview != ntested) FAIL(sprintf("tcgas rows %s != tested %s for %s", nview, ntested, gene))
    else if (!is.na(nnull) && nnull > 0) FAIL("tcgas has NULL values (should be 0-filled)")
    else PASS(sprintf("%s: %s dense rows", gene, nview))
  })
  add("views", "tcgas sparse-zero accounting is consistent", function() {
    if (is.na(gene)) return(SKIP("no numeric probe"))
    nz   <- .q1(con, sprintf("SELECT COUNT(*) FROM tcgas WHERE probe='%s' AND value<>0", gene))
    zero <- .q1(con, sprintf("SELECT COUNT(*) FROM tcgas WHERE probe='%s' AND value=0",  gene))
    stored_nz <- .q1(con, sprintf("SELECT COUNT(*) FROM tcgai dat JOIN probes pr ON pr.key=dat.probekey
                                   WHERE pr.probe='%s' AND dat.value<>0", gene))
    if (nz != stored_nz) FAIL(sprintf("nonzero view rows %s != stored nonzero %s", nz, stored_nz))
    else PASS(sprintf("%s: %s expressed / %s sparse-zero", gene, nz, zero))
  })
  add("views", "tcga view exposes clinpheno columns", function() {
    vc <- .cols(con, "tcga")
    miss <- setdiff(clin_cols, vc)
    if (length(miss)) FAIL(paste("clinpheno cols missing from tcga view:", paste(miss, collapse=", ")))
    else PASS()
  })

  ## --- ROLE MAP / COHORTS ---
  add("roles", "cohort_col is a clinpheno column", function() {
    if (is.na(ccol)) return(SKIP("no cohort_col"))
    if (!ccol %in% clin_cols) FAIL(sprintf("cohort_col '%s' not in clinpheno", ccol)) else PASS(ccol)
  })
  add("roles", "subtype_col is a clinpheno column", function() {
    sc <- roles$subtype_col
    if (is.null(sc) || is.na(sc) || !nzchar(sc)) return(SKIP("no subtype_col"))
    if (!sc %in% clin_cols) FAIL(sprintf("subtype_col '%s' not in clinpheno", sc)) else PASS(sc)
  })
  add("roles", "sampletype_col is a clinpheno column", function() {
    if (is.na(stc)) return(SKIP("no sampletype_col"))
    if (!stc %in% clin_cols) FAIL(sprintf("sampletype_col '%s' not in clinpheno", stc)) else PASS(stc)
  })
  add("roles", "cohorts table has no NULL/blank cohort", function() {
    if (!.has(con, "cohorts")) return(SKIP("no cohorts table"))
    bad <- .q1(con, "SELECT COUNT(*) FROM cohorts WHERE cohort IS NULL OR TRIM(cohort)=''")
    if (is.na(bad)) return(SKIP("no cohort column"))
    if (bad != 0) FAIL(sprintf("%d blank cohort rows (would show as empty dropdown entries)", bad))
    else PASS()
  })
  add("roles", "cohorts table matches distinct cohort_col values", function() {
    if (is.na(ccol) || !.has(con, "cohorts")) return(SKIP("no cohorts/cohort_col"))
    disc <- sort(unique(.qdf(con, sprintf('SELECT DISTINCT "%s" AS v FROM clinpheno
                                           WHERE "%s" IS NOT NULL', ccol, ccol))$v))
    coh  <- sort(unique(.qdf(con, "SELECT cohort FROM cohorts")$cohort))
    if (!setequal(disc, coh))
      FAIL(sprintf("cohorts(%d) != distinct %s(%d); e.g. missing {%s}",
                   length(coh), ccol, length(disc),
                   paste(head(setdiff(disc, coh), 3), collapse=", ")))
    else PASS(sprintf("%d cohorts", length(coh)))
  })

  ## --- GITR (the actual app data path) ---
  add("gitr", "gitr(gene) returns rows with sample + gene column", function() {
    if (is.na(gene)) return(SKIP("no numeric probe"))
    d <- gitr_quiet(gene)
    if (is.null(d) || nrow(d) == 0) FAIL("no rows")
    else if (!"sample" %in% names(d)) FAIL("no sample column")
    else if (!gene %in% names(d)) FAIL(sprintf("gene column '%s' absent", gene))
    else PASS(sprintf("%d rows", nrow(d)))
  })
  add("gitr", "gitr synthesises cohort/subtype virtual columns", function() {
    if (is.na(gene)) return(SKIP("no numeric probe"))
    d <- gitr_quiet(gene)
    need <- c(if (!is.na(ccol)) "cohort",
              if (role_has("subtype_col")) "subtype")
    if (!length(need)) return(SKIP("no cohort/subtype role"))
    miss <- need[!need %in% names(d)]
    if (length(miss)) FAIL(paste("missing virtual cols:", paste(miss, collapse=", "))) else PASS(paste(need, collapse=","))
  })
  add("gitr", "nonormal filter reduces rows when normals exist", function() {
    if (is.na(gene) || is.na(stc)) return(SKIP("no sampletype_col"))
    nl <- roles$normal_label; nl <- nl[!is.na(nl)]
    if (!length(nl)) return(SKIP("no normal_label"))
    nnorm <- .q1(con, sprintf('SELECT COUNT(*) FROM clinpheno WHERE "%s" IN (%s)',
                              stc, paste(sprintf("'%s'", nl), collapse=",")))
    a <- nrow(gitr_quiet(gene, nonormal = FALSE))
    b <- nrow(gitr_quiet(gene, nonormal = TRUE))
    if (nnorm > 0 && !(b < a)) FAIL(sprintf("nonormal did not reduce rows (%d -> %d, %d normals)", a, b, nnorm))
    else if (b > a) FAIL("nonormal increased rows") else PASS(sprintf("%d -> %d", a, b))
  })
  add("gitr", "cohort filter subsets to one cohort", function() {
    if (is.na(gene) || is.na(ccol)) return(SKIP("no cohort_col"))
    one <- .q1(con, sprintf('SELECT "%s" FROM clinpheno WHERE "%s" IS NOT NULL LIMIT 1', ccol, ccol))
    if (is.na(one)) return(SKIP("no cohort value"))
    d <- gitr_quiet(gene, cohort = one)
    if (nrow(d) == 0) return(FAIL(sprintf("no rows for cohort '%s'", one)))
    if (!"cohort" %in% names(d)) return(SKIP("no cohort column"))
    bad <- sum(as.character(d$cohort) != one, na.rm = TRUE)
    if (bad != 0) FAIL(sprintf("%d rows leaked outside cohort '%s'", bad, one)) else PASS(one)
  })
  add("gitr", "gitr on a clinical column returns it", function() {
    if (is.na(ccol)) return(SKIP("no cohort_col"))
    d <- gitr_quiet(ccol)
    if (!ccol %in% names(d)) FAIL(sprintf("clinical column '%s' absent", ccol)) else PASS()
  })
  add("gitr", "two-gene scatter returns both columns", function() {
    if (is.na(gene) || is.na(gene2)) return(SKIP("need 2 numeric probes"))
    d <- gitr_quiet(c(gene, gene2))
    if (all(c(gene, gene2) %in% names(d))) PASS() else FAIL("a gene column is missing")
  })
  add("gitr", "categorical probe returns a column", function() {
    if (is.na(cat_probe)) return(SKIP("no categorical probe"))
    d <- gitr_quiet(cat_probe)
    if (cat_probe %in% names(d)) PASS() else FAIL(sprintf("categorical '%s' absent", cat_probe))
  })

  ## --- HUMAN / SHINY QUERY PATTERNS (raw SQL) ---
  add("queries", "expression of a gene grouped by cohort", function() {
    if (is.na(gene) || is.na(ccol)) return(SKIP("need gene + cohort_col"))
    d <- .qdf(con, sprintf('SELECT "%s" AS cohort, COUNT(*) n, AVG(value) mean
                            FROM tcga WHERE probe = \'%s\' GROUP BY "%s" ORDER BY mean DESC',
                           ccol, gene, ccol))
    if (nrow(d) == 0) FAIL("no groups") else PASS(sprintf("%d cohorts; top=%s", nrow(d), d$cohort[1]))
  })
  add("queries", "list distinct cohorts", function() {
    if (is.na(ccol)) return(SKIP("no cohort_col"))
    n <- .q1(con, sprintf('SELECT COUNT(DISTINCT "%s") FROM clinpheno', ccol))
    if (is.na(n) || n == 0) FAIL("no cohort values") else PASS(sprintf("%d", n))
  })
  add("queries", "per-cohort sample counts", function() {
    if (is.na(ccol)) return(SKIP("no cohort_col"))
    d <- .qdf(con, sprintf('SELECT "%s" c, COUNT(*) n FROM clinpheno GROUP BY "%s"', ccol, ccol))
    if (nrow(d) == 0) FAIL("empty") else PASS(sprintf("%d cohorts, %d samples", nrow(d), sum(d$n)))
  })
  add("queries", "two-probe scatter via self-join on sample", function() {
    if (is.na(gene) || is.na(gene2)) return(SKIP("need 2 numeric probes"))
    n <- .q1(con, sprintf("SELECT COUNT(*) FROM
      (SELECT sample,value FROM tcgas WHERE probe='%s') a
      JOIN (SELECT sample,value FROM tcgas WHERE probe='%s') b USING(sample)", gene, gene2))
    if (is.na(n) || n == 0) FAIL("no joined rows") else PASS(sprintf("%d paired samples", n))
  })
  add("performance", "single-probe tcgas query is reasonably fast", function() {
    if (is.na(gene)) return(SKIP("no numeric probe"))
    t <- system.time(.qdf(con, sprintf("SELECT sample,value FROM tcgas WHERE probe='%s'", gene)))[["elapsed"]]
    if (t > 60) FAIL(sprintf("%.1fs (>60s) -- check indexes", t)) else PASS(sprintf("%.2fs", t))
  })
  add("serving", "db is in WAL journal mode (readers never block writers)", function() {
    jm <- .q1(con, "PRAGMA journal_mode")
    if (identical(tolower(jm), "wal")) PASS(jm)
    else WARN(sprintf("journal_mode=%s (not WAL: a held read lock can block a maintenance writer)", jm))
  })
  add("performance", "categorical type filter uses an index (not full SCAN)", function() {
    ctype <- .q1(con, "SELECT type FROM tcgacati LIMIT 1")
    if (is.na(ctype)) return(SKIP("no categorical data"))
    ## the driving table access for `... WHERE type = X` on tcgacats must be an
    ## indexed SEARCH; a SCAN means the type-leading index is missing.
    plan <- .qdf(con, sprintf(
      "EXPLAIN QUERY PLAN SELECT sample,probe,value FROM tcgacats WHERE type='%s'", ctype))
    scans <- any(grepl("^SCAN", plan$detail) & grepl("\\bdat\\b", plan$detail))
    if (scans) FAIL(sprintf("tcgacats WHERE type='%s' SCANs tcgacati -- add tcgacatiidx_tsp(type,...)", ctype))
    else PASS(sprintf("type='%s' indexed", ctype))
  })
  add("performance", "categorical PROBE query uses an index (not full SCAN)", function() {
    ## gitr looks up categorical data BY PROBE (mutations/subtypes) via tcgacats;
    ## this must be an indexed SEARCH, else the probekey-leading index is missing.
    cp <- .q1(con, "SELECT pr.probe FROM probes pr JOIN tcgacati d ON d.probekey=pr.key LIMIT 1")
    if (is.na(cp)) return(SKIP("no categorical data"))
    plan <- .qdf(con, sprintf(
      "EXPLAIN QUERY PLAN SELECT sample,probe,value FROM tcgacats WHERE probe='%s'", cp))
    scans <- any(grepl("^SCAN", plan$detail) & grepl("\\bdat\\b", plan$detail))
    if (scans) FAIL(sprintf("tcgacats WHERE probe='%s' SCANs tcgacati -- add tcgacatiidx_pts(probekey,...)", cp))
    else PASS(sprintf("probe='%s' indexed", cp))
  })

  ## ---- run ------------------------------------------------------------------
  res <- data.frame(group=character(), test=character(), status=character(),
                    detail=character(), stringsAsFactors = FALSE)
  for (tt in tests) {
    r <- tryCatch(tt$fn(), error = function(e) FAIL(paste("ERROR:", conditionMessage(e))))
    status <- if (is.list(r) && isTRUE(r$warn)) "WARN"
              else if (is.list(r) && is.na(r$ok)) "SKIP"
              else if (isTRUE(r$ok)) "PASS" else "FAIL"
    res <- rbind(res, data.frame(group=tt$group, test=tt$name, status=status,
                                 detail=ifelse(is.null(r$detail), "", r$detail),
                                 stringsAsFactors = FALSE))
  }

  if (verbose) {
    cat(sprintf("\n==== SQL test suite: %s  (dataset '%s') ====\n", dbpath, ri$name))
    mark <- c(PASS="  ok ", FAIL="FAIL ", SKIP="skip ", WARN="warn ")
    for (i in seq_len(nrow(res)))
      cat(sprintf("%s [%-11s] %-52s %s\n", mark[res$status[i]], res$group[i],
                  res$test[i], res$detail[i]))
    np <- sum(res$status=="PASS"); nf <- sum(res$status=="FAIL")
    ns <- sum(res$status=="SKIP"); nw <- sum(res$status=="WARN")
    cat(sprintf("---- %d PASS / %d FAIL / %d WARN / %d SKIP ----\n", np, nf, nw, ns))
  }
  invisible(list(results = res, ok = !any(res$status == "FAIL")))
}

## ---- CLI -------------------------------------------------------------------
## Only act as a script when invoked directly (Rscript sql_tests.R <db>),
## never when source()'d from 00-master.R or another script.
.invoked_directly <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  length(fa) && identical(basename(sub("^--file=", "", fa[1])), "sql_tests.R")
}
if (.invoked_directly()) {
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a) >= 1) {
    out <- run_sql_tests(a[1], if (length(a) >= 2) a[2] else NULL)
    quit(status = if (out$ok) 0 else 1)
  } else {
    cat("usage: Rscript sql_tests.R <db-path> [dataset-name]\n")
  }
}
