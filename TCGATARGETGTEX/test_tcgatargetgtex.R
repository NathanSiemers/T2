## TCGATARGETGTEX/test_tcgatargetgtex.R
## ============================================================================
## Tests specific to the TCGA-TARGET-GTEx dataset: the Ensembl->HGNC collapse
## math, and the built datasets/tcgatargetgtex.db's key facts. Also runs the
## generic T2 suite (../sql_tests.R) against it.
##   Rscript TCGATARGETGTEX/test_tcgatargetgtex.R
## ============================================================================

suppressMessages({ library(DBI); library(RSQLite); library(data.table) })

## run from repo root so dataset_registry / relative db paths resolve
.f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
ROOT <- if (length(.f)) normalizePath(file.path(dirname(sub("^--file=", "", .f[1])), "..")) else getwd()
setwd(ROOT)
source("ensembl_to_hgnc.R"); source("gitr.R"); source("dataset_registry.R")

np <- 0; nf <- 0
ok <- function(cond, msg, detail = "") {
  cond <- isTRUE(cond); if (cond) np <<- np + 1 else nf <<- nf + 1
  cat(sprintf("  %s %-52s %s\n", if (cond) " ok " else "FAIL", msg, detail))
}
near <- function(a, b, tol = 1e-4) all(abs(a - b) < tol)

## ---------------------------------------------------------------------------
cat("\n== Ensembl -> HGNC collapse (unit) ==\n")
## GENEA: two Ensembl ids share it -> sum in LINEAR space
## ENSG4: no symbol -> kept as-is ; ENSG5: two symbols -> dropped
pm <- data.frame(
  id   = c("ENSG1.1","ENSG2.1","ENSG3.1","ENSG4.1","ENSG5.1","ENSG5.1"),
  gene = c("GENEA",  "GENEA",  "GENEB",  "",        "SYMX",   "SYMY"),
  stringsAsFactors = FALSE)
map <- load_ensembl_hgnc_map(pm, verbose = FALSE)
ok(identical(unname(map["ENSG1.1"]), "GENEA"),      "map: ENSG1 -> GENEA")
ok(!("ENSG4.1" %in% names(map)),                    "map: empty-symbol id excluded")
ok(!("ENSG5.1" %in% names(map)),                    "map: ambiguous id (>1 symbol) excluded")

l2 <- function(tpm) log2(tpm + 0.001)                     # source scale
expr <- data.table(id = c("ENSG1.1","ENSG2.1","ENSG3.1","ENSG4.1","ENSG5.1"),
                   S1 = l2(c(3, 1, 10, 5, 7)),
                   S2 = l2(c(0, 0,  2, 0, 7)))
coll <- as.data.table(collapse_ensembl_to_hgnc(expr, map, verbose = FALSE))
val <- function(p, s) coll[probe == p][[s]]
ok(near(val("GENEA","S1"), log2(3 + 1 + 1)), "collapse: GENEA = log2(sum(tpm)+1) linear", "log2(5)")
ok(near(val("GENEA","S2"), 0),               "collapse: all-zero gene -> 0 (sparse)")
ok(near(val("GENEB","S1"), log2(10 + 1)),    "collapse: GENEB S1 = log2(11)")
ok(nrow(coll[probe == "ENSG4.1"]) == 1 && near(val("ENSG4.1","S1"), log2(5 + 1)),
   "collapse: unmapped Ensembl kept as-is")
ok(nrow(coll[probe == "ENSG5.1"]) == 0,      "collapse: ambiguous Ensembl DROPPED")

## ---------------------------------------------------------------------------
DB <- "datasets/tcgatargetgtex.db"
if (!file.exists(DB)) {
  cat("\n(dataset", DB, "not built — skipping db + suite tests)\n")
} else {
  cat("\n== Built dataset facts ==\n")
  con <- dbConnect(SQLite(), DB, flags = SQLITE_RO)
  q1 <- function(s) dbGetQuery(con, s)[1, 1]
  st <- dbGetQuery(con, "SELECT study, COUNT(*) n FROM clinpheno GROUP BY study")
  studies <- setNames(st$n, st$study)
  ok(sum(st$n) == 19131, "19,131 samples total", paste(sum(st$n)))
  ok(studies[["TCGA"]] == 10535 && studies[["GTEX"]] == 7862 && studies[["TARGET"]] == 734,
     "study split TCGA/GTEX/TARGET", "10535 / 7862 / 734")
  ok(q1("SELECT COUNT(*) FROM probes") == 58581, "58,581 gene probes")
  ok(q1("SELECT type FROM types") == "rna" && q1("SELECT COUNT(*) FROM types") == 1,
     "single data type: rna")
  ok(q1("SELECT COUNT(*) FROM tcgacati") == 0, "no categorical data (tcgacati empty)")
  ok(q1("SELECT COUNT(*) FROM cohorts") == 93, "93 cohorts (diseases/tissues)")
  ok(q1("SELECT cohortstring FROM cohorts WHERE cohort='Whole Blood'") == "Whole Blood (GTEX)",
     "cohort labelled with its study")
  ## value scale: stored rna values are log2(TPM+1) -> strictly > 0, sane max
  sc <- dbGetQuery(con, "SELECT MIN(value) mn, MAX(value) mx FROM tcgai")
  ok(sc$mn > 0 && sc$mx < 25, "rna values are log2(TPM+1) (>0, sane max)",
     sprintf("[%.3f, %.2f]", sc$mn, sc$mx))
  dbDisconnect(con)

  cat("\n== Role map + biology (via gitr) ==\n")
  roles <- dataset_info("tcgatargetgtex")$roles
  ok(roles$cohort_col == "disease" && roles$subtype_col == "study" &&
     roles$sampletype_col == "sample_type", "role map: cohort=disease, subtype=study")
  ok(length(roles$normal_label[!is.na(roles$normal_label)]) == 3,
     "multi-value normal_label (3 non-tumor types)")
  d <- suppressWarnings(gitr(c("CD8A", "study"), dbfile = DB, roles = roles))
  m <- tapply(d$CD8A, d$study, mean, na.rm = TRUE)
  ok(m[["GTEX"]] < m[["TCGA"]], "CD8A: GTEX(normal) < TCGA(tumor)",
     sprintf("GTEX %.2f < TCGA %.2f", m[["GTEX"]], m[["TCGA"]]))
  a <- nrow(suppressWarnings(gitr("CD8A", dbfile = DB, roles = roles)))
  b <- nrow(suppressWarnings(gitr("CD8A", dbfile = DB, roles = roles, nonormal = TRUE)))
  ok(b < a, "nonormal drops non-tumor samples", sprintf("%d -> %d", a, b))

  cat("\n== Generic T2 suite (../sql_tests.R) ==\n")
  source("sql_tests.R")
  r <- run_sql_tests(DB, "tcgatargetgtex", verbose = FALSE)
  fails <- r$results[r$results$status == "FAIL", ]
  ok(r$ok, "generic SQL suite: no FAILs",
     sprintf("%d checks", nrow(r$results)))
  if (nrow(fails)) for (i in seq_len(nrow(fails))) cat("      FAIL:", fails$test[i], "-", fails$detail[i], "\n")
}

cat(sprintf("\n==== %d PASS / %d FAIL ====\n", np, nf))
if (!length(grep("^--file=", commandArgs(FALSE)))) invisible() else quit(status = if (nf > 0) 1 else 0)
