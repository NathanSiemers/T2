################################################################
## Test suite for categorical sparse conversion
## Tests both raw SQL and gitr() paths
##
## Run BEFORE changes to generate baseline:
##   Rscript Testing/test_categorical_sparse.R baseline
## Run AFTER changes to verify:
##   Rscript Testing/test_categorical_sparse.R verify

library(DBI)
library(dplyr)
library(tidyverse)
source("gitr.R")

args = commandArgs(trailingOnly = TRUE)
mode = if (length(args) > 0) args[1] else "baseline"
baseline_file = "Testing/categorical_sparse_baseline.rds"
dbfile = "tcga.db"

con_ro = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO)

cat(sprintf("=== Categorical sparse test: %s mode ===\n", mode))

results = list()

################################################################
## SQL-level tests (for types still in the dense view)

cat("\n--- Dense view tests (molec_subtype, immune_subtype) ---\n")

sql_tests = list(
  subtype_selected = list(
    desc = "Subtype_Selected from tcgacats",
    query = "SELECT sample, value FROM tcgacats
             WHERE probe = 'Subtype_Selected.molec_subtype' AND value IS NOT NULL
             ORDER BY sample LIMIT 20"
  ),
  immune_subtype = list(
    desc = "immune_subtype values",
    query = "SELECT value, count(*) as n FROM tcgacats
             WHERE type = 'immune_subtype' GROUP BY value ORDER BY n DESC LIMIT 10"
  )
)
for (name in names(sql_tests)) {
  tq = sql_tests[[name]]
  cat(sprintf("  %-50s ... ", tq$desc))
  t0 = proc.time()["elapsed"]
  r = dbGetQuery(con_ro, tq$query)
  t1 = proc.time()["elapsed"]
  results[[name]] = r
  cat(sprintf("%d rows (%.2fs)\n", nrow(r), t1 - t0))
}

################################################################
## gitr-level tests (the actual code path)

cat("\n--- gitr tests ---\n")

gitr_tests = list(
  gitr_fmut_TP53 = list(
    desc = "gitr: TP53.fmut values",
    fn = function() {
      d = gitr(c("TP53.fmut"), phenos = FALSE)
      data.frame(
        total = nrow(d),
        non_na = sum(!is.na(d$TP53.fmut)),
        na = sum(is.na(d$TP53.fmut)),
        stringsAsFactors = FALSE
      )
    }
  ),
  gitr_fmut_nonnull = list(
    desc = "gitr: TP53.fmut non-NA values (first 10)",
    fn = function() {
      d = gitr(c("TP53.fmut"), phenos = FALSE)
      d = d[!is.na(d$TP53.fmut), ]
      head(d[order(d$sample), c("sample", "TP53.fmut")], 10)
    }
  ),
  gitr_fmut_multi = list(
    desc = "gitr: 3 fmut probes, non-NA counts",
    fn = function() {
      d = gitr(c("TP53.fmut", "KRAS.fmut", "BRAF.fmut"), phenos = FALSE)
      data.frame(
        probe = c("TP53.fmut", "KRAS.fmut", "BRAF.fmut"),
        non_na = c(sum(!is.na(d$TP53.fmut)), sum(!is.na(d$KRAS.fmut)), sum(!is.na(d$BRAF.fmut))),
        stringsAsFactors = FALSE
      )
    }
  ),
  gitr_subtype = list(
    desc = "gitr: Subtype_Selected.molec_subtype",
    fn = function() {
      d = gitr(c("Subtype_Selected.molec_subtype"), phenos = FALSE)
      data.frame(
        total = nrow(d),
        non_na = sum(!is.na(d$Subtype_Selected.molec_subtype)),
        stringsAsFactors = FALSE
      )
    }
  ),
  gitr_mixed = list(
    desc = "gitr: mixed numeric + fmut + subtype",
    fn = function() {
      d = gitr(c("CD8A", "TP53.fmut", "Subtype_Selected.molec_subtype"), phenos = FALSE)
      data.frame(
        probe = c("CD8A", "TP53.fmut", "Subtype_Selected.molec_subtype"),
        non_na = c(sum(!is.na(d$CD8A)),
                   sum(!is.na(d$TP53.fmut)),
                   sum(!is.na(d$Subtype_Selected.molec_subtype))),
        stringsAsFactors = FALSE
      )
    }
  ),
  gitr_fmut_brca = list(
    desc = "gitr: TP53.fmut for BRCA cohort",
    fn = function() {
      d = gitr(c("TP53.fmut"), cohort = "BRCA", phenos = TRUE)
      d = d[!is.na(d$TP53.fmut), ]
      head(d[order(d$sample), c("sample", "TP53.fmut")], 10)
    }
  ),
  gitr_immune_subtype = list(
    desc = "gitr: immune_subtype",
    fn = function() {
      d = gitr(c("Subtype_Immune_Model_Based.immune_subtype"), phenos = FALSE)
      data.frame(
        total = nrow(d),
        non_na = sum(!is.na(d$Subtype_Immune_Model_Based.immune_subtype)),
        stringsAsFactors = FALSE
      )
    }
  )
)

for (name in names(gitr_tests)) {
  gt = gitr_tests[[name]]
  cat(sprintf("  %-50s ... ", gt$desc))
  t0 = proc.time()["elapsed"]
  r = gt$fn()
  t1 = proc.time()["elapsed"]
  results[[name]] = r
  cat(sprintf("%d rows (%.2fs)\n", nrow(r), t1 - t0))
}

dbDisconnect(con_ro)

################################################################
## Save or verify

if (mode == "baseline") {
  saveRDS(results, baseline_file)
  cat(sprintf("\nBaseline saved to %s (%d tests)\n", baseline_file, length(results)))

} else if (mode == "verify") {
  if (!file.exists(baseline_file)) {
    stop("No baseline found! Run with 'baseline' first.")
  }
  baseline = readRDS(baseline_file)
  cat("\n=== Verification ===\n")
  pass = 0; fail = 0
  for (name in names(results)) {
    current = results[[name]]
    expected = baseline[[name]]
    if (is.null(expected)) {
      cat(sprintf("  SKIP  %-50s (not in baseline)\n", name))
      next
    }
    match = identical(current, expected)
    if (match) {
      cat(sprintf("  PASS  %-50s\n", name))
      pass = pass + 1
    } else {
      cat(sprintf("  FAIL  %-50s\n", name))
      cat("    Expected:\n"); print(head(expected, 5))
      cat("    Got:\n"); print(head(current, 5))
      fail = fail + 1
    }
  }
  cat(sprintf("\n%d passed, %d failed out of %d tests\n", pass, fail, pass + fail))
  if (fail > 0) quit(status = 1)

} else {
  cat("Usage: Rscript Testing/test_categorical_sparse.R [baseline|verify]\n")
}
