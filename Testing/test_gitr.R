## Test suite for gitr.R
## Validates datatypes, value semantics, performance, and edge cases

library(DBI)
library(dplyr)
library(RSQLite)

gitrdb = "tcga.db"
source("gitr.R")

pass = 0; fail = 0
test = function(name, expr) {
  result = tryCatch(expr, error = function(e) { cat("  ERROR:", e$message, "\n"); FALSE })
  if (isTRUE(result)) { pass <<- pass + 1; cat(sprintf("  PASS %s\n", name)) }
  else { fail <<- fail + 1; cat(sprintf("  FAIL %s\n", name)) }
}

## ---------------------------------------------------------------
## 1. Datatype tests
## ---------------------------------------------------------------
cat("=== DATATYPE TESTS ===\n")
probes_dt = c("FOXP3", "CD8A", "TP53.mut", "CDKN2A.mut", "CDKN2A.cnv",
              "CDKN2A.cnc", "HRD.hrd", "StromalScore.estimate",
              "TregCD8.sig", "TP53.fmut", "muttest.muttest")
out_dt = gitr(probes_dt, phenos = TRUE)

test("FOXP3 is numeric",                is.numeric(out_dt$FOXP3))
test("CD8A is numeric",                 is.numeric(out_dt$CD8A))
test("TP53.mut is factor",              is.factor(out_dt$TP53.mut))
test("CDKN2A.mut is factor",            is.factor(out_dt$CDKN2A.mut))
test("CDKN2A.cnv is numeric",           is.numeric(out_dt$CDKN2A.cnv))
test("CDKN2A.cnc is factor",            is.factor(out_dt$CDKN2A.cnc))
test("HRD.hrd is numeric",              is.numeric(out_dt$HRD.hrd))
test("StromalScore.estimate is numeric", is.numeric(out_dt$StromalScore.estimate))
test("TregCD8.sig is numeric",          is.numeric(out_dt$TregCD8.sig))
test("TP53.fmut is factor",             is.factor(out_dt$TP53.fmut))
test("muttest.muttest is factor",       is.factor(out_dt$muttest.muttest))

## ---------------------------------------------------------------
## 2. Value semantics (0 vs NA)
## ---------------------------------------------------------------
cat("\n=== VALUE SEMANTICS ===\n")
out_val = gitr(c("TP53.mut", "HRD.hrd", "CCR8"), phenos = TRUE)

test("TP53.mut has zeros (tested wild-type)",
     sum(out_val$TP53.mut == "0", na.rm = TRUE) > 5000)
test("TP53.mut has NAs (untested samples)",
     sum(is.na(out_val$TP53.mut)) > 3000)
test("HRD.hrd has zeros (tested, score=0)",
     sum(out_val$HRD.hrd == 0, na.rm = TRUE) > 1000)
test("HRD.hrd has NAs (untested)",
     sum(is.na(out_val$HRD.hrd)) > 2000)
test("CCR8 has zeros (undetected expression)",
     sum(out_val$CCR8 == 0, na.rm = TRUE) > 1000)

## ---------------------------------------------------------------
## 3. Virtual columns (subtype, cohort, lcohort)
## ---------------------------------------------------------------
cat("\n=== VIRTUAL COLUMNS ===\n")
out_vc = gitr(c("FOXP3", "subtype", "cohort", "sample_type"), phenos = TRUE)

test("subtype column exists",           "subtype" %in% colnames(out_vc))
test("cohort column exists",            "cohort" %in% colnames(out_vc))
test("no subtype.x collision",          !"subtype.x" %in% colnames(out_vc))
test("no cohort.x collision",           !"cohort.x" %in% colnames(out_vc))
test("subtype has values",              !all(is.na(out_vc$subtype)))
test("cohort has 34 tumor types",       length(unique(out_vc$cohort)) >= 33)

## ---------------------------------------------------------------
## 4. Clinpheno columns as probes
## ---------------------------------------------------------------
cat("\n=== CLINPHENO COLUMNS ===\n")
out_cp = gitr(c("FOXP3", "sample_type", "gender"), phenos = TRUE)

test("sample_type is factor",           is.factor(out_cp$sample_type))
test("gender is factor",                is.factor(out_cp$gender))
test("sample_type has factor levels",   length(levels(out_cp$sample_type)) >= 5)

## ---------------------------------------------------------------
## 5. Filters
## ---------------------------------------------------------------
cat("\n=== FILTERS ===\n")
out_filt = gitr(c("FOXP3"), phenos = TRUE, nonormal = TRUE, noheme = TRUE,
                cohort = c("BRCA", "LUAD"))

test("cohort filter works",
     all(out_filt$cohort %in% c("BRCA", "LUAD")))
test("nonormal excludes normals",
     !"Solid Tissue Normal" %in% as.character(out_filt$sample_type))
test("noheme excludes LAML/THYM/DLBC",
     !any(out_filt$tumtype %in% c("LAML", "THYM", "DLBC")))

## ---------------------------------------------------------------
## 6. phenos=FALSE
## ---------------------------------------------------------------
cat("\n=== PHENOS=FALSE ===\n")
out_np = gitr(c("FOXP3", "TP53.mut"), phenos = FALSE)

test("phenos=FALSE returns only sample + probes",
     all(colnames(out_np) %in% c("sample", "FOXP3", "TP53.mut")))
test("phenos=FALSE has all samples",
     nrow(out_np) >= 12000)

## ---------------------------------------------------------------
## 7. Performance
## ---------------------------------------------------------------
cat("\n=== PERFORMANCE ===\n")
con2 = dbConnect(SQLite(), "tcga.db", flags = SQLITE_RO)
all_probes = dbGetQuery(con2, "SELECT probe FROM allprobes")$probe
dbDisconnect(con2)

## 8 probes
times_8 = numeric(5)
for (i in 1:5) {
  t0 = proc.time()["elapsed"]
  gitr(c("FOXP3","CD8A","TP53.mut","CDKN2A.cnv","CDKN2A.cnc","HRD.hrd","StromalScore.estimate","TregCD8.sig"))
  times_8[i] = proc.time()["elapsed"] - t0
}
cat(sprintf("  8 probes:   median %.2f s\n", median(times_8)))
test("8 probes under 3s", median(times_8) < 3)

## 100 probes
times_100 = numeric(5)
for (i in 1:5) {
  t0 = proc.time()["elapsed"]
  gitr(sample(all_probes, 100))
  times_100[i] = proc.time()["elapsed"] - t0
}
cat(sprintf("  100 probes: median %.2f s\n", median(times_100)))
test("100 probes under 15s", median(times_100) < 15)

## ---------------------------------------------------------------
## Summary
## ---------------------------------------------------------------
cat(sprintf("\n=== SUMMARY: %d passed, %d failed ===\n", pass, fail))
