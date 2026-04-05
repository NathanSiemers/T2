## Benchmark: proto_get_tcga.R (make_query) vs gitr.R for sparse data retrieval
## Probes: c("CDKN2A.cnv", "CDKN2A.mut", "CCR8", "FOXP3", "CD3E", "CD3D", "TP53.mut")

library(sqldf)
library(data.table)
library(DBI)
library(dplyr)

db <- 'tcga.db'
probes <- c("CDKN2A.cnv", "CDKN2A.mut", "CCR8", "FOXP3", "CD3E", "CD3D", "TP53.mut")

cat("=== DATABASE INDEXES ===\n")
idx <- sqldf("SELECT name, tbl_name, sql FROM sqlite_master WHERE type='index' ORDER BY tbl_name", dbname = db)
print(idx)

## ---------------------------------------------------------------
## 1. proto_get_tcga.R  (make_query) — single batch query
## ---------------------------------------------------------------
## Only source the make_query function, not the whole script
eval(parse(text = readLines("proto_get_tcga.R")[1:63]))

cat("\n=== PROTO_GET_TCGA: make_query (probes only, types auto-derived) ===\n")
proto_query <- make_query(probes = probes, db = db)
cat(proto_query, "\n\n")

cat("--- Query plan ---\n")
plan <- sqldf(paste("EXPLAIN QUERY PLAN", proto_query), dbname = db)
print(plan)

cat("\n--- Timing 20 runs (proto make_query, single batch) ---\n")
proto_times <- numeric(20)
for (i in seq_along(proto_times)) {
  t0 <- proc.time()["elapsed"]
  res <- sqldf(proto_query, dbname = db)
  proto_times[i] <- proc.time()["elapsed"] - t0
}
cat(sprintf("  Rows returned: %d\n", nrow(res)))
cat(sprintf("  Mean: %.4f s  |  Median: %.4f s  |  Min: %.4f s  |  Max: %.4f s\n",
            mean(proto_times), median(proto_times), min(proto_times), max(proto_times)))
proto_result <- res

## ---------------------------------------------------------------
## 2. proto_get_tcga.R — individual queries (one probe at a time)
## ---------------------------------------------------------------
cat("\n=== PROTO_GET_TCGA: make_query (one probe at a time, 7 queries) ===\n")
single_times <- numeric(20)
for (i in seq_along(single_times)) {
  t0 <- proc.time()["elapsed"]
  parts <- lapply(probes, function(p) sqldf(make_query(probes = p, db = db), dbname = db))
  combined <- rbindlist(parts)
  single_times[i] <- proc.time()["elapsed"] - t0
}
cat(sprintf("  Mean: %.4f s  |  Median: %.4f s  |  Min: %.4f s  |  Max: %.4f s\n",
            mean(single_times), median(single_times), min(single_times), max(single_times)))

## ---------------------------------------------------------------
## 3. gitr.R equivalent — parallel probe-by-probe with tested backfill
## ---------------------------------------------------------------
cat("\n=== GITR.R: probe-by-probe with furrr (6 workers) ===\n")

## We need gitr loaded but with its own db path
gitrdb <- db
source("gitr.R")

gitr_times <- numeric(20)
for (i in seq_along(gitr_times)) {
  t0 <- proc.time()["elapsed"]
  gitr_res <- gitr(probes, phenos = FALSE, makefactors = FALSE)
  gitr_times[i] <- proc.time()["elapsed"] - t0
}
cat(sprintf("  Rows returned: %d x %d\n", nrow(gitr_res), ncol(gitr_res)))
cat(sprintf("  Mean: %.4f s  |  Median: %.4f s  |  Min: %.4f s  |  Max: %.4f s\n",
            mean(gitr_times), median(gitr_times), min(gitr_times), max(gitr_times)))

## ---------------------------------------------------------------
## 4. gitr.R — sequential (no furrr) for fair comparison
## ---------------------------------------------------------------
cat("\n=== GITR sequential (purrr::map, 1 worker) ===\n")
gitr_seq_times <- numeric(20)
old_plan <- future::plan("sequential")
for (i in seq_along(gitr_seq_times)) {
  t0 <- proc.time()["elapsed"]
  gitr_seq_res <- gitr(probes, phenos = FALSE, makefactors = FALSE)
  gitr_seq_times[i] <- proc.time()["elapsed"] - t0
}
future::plan(old_plan)
cat(sprintf("  Mean: %.4f s  |  Median: %.4f s  |  Min: %.4f s  |  Max: %.4f s\n",
            mean(gitr_seq_times), median(gitr_seq_times), min(gitr_seq_times), max(gitr_seq_times)))

## ---------------------------------------------------------------
## 5. Result correctness comparison
## ---------------------------------------------------------------
cat("\n=== CORRECTNESS CHECK ===\n")
## Pivot proto result to wide
proto_wide <- dcast(as.data.table(proto_result), sample ~ probe, value.var = "value", fill = NA)
setkey(proto_wide, sample)

gitr_dt <- as.data.table(gitr_res)
setkey(gitr_dt, sample)

## Compare overlapping columns
common_probes <- intersect(names(proto_wide), names(gitr_dt))
common_probes <- common_probes[common_probes != "sample"]
cat("Common probes to compare:", paste(common_probes, collapse=", "), "\n")

for (p in common_probes) {
  common_samp <- intersect(proto_wide$sample, gitr_dt$sample)
  pw <- proto_wide[common_samp, ..p][[1]]
  gw <- gitr_dt[common_samp, ..p][[1]]
  ## Compare treating NA as equal
  match_count <- sum( (is.na(pw) & is.na(gw)) | (!is.na(pw) & !is.na(gw) & pw == gw), na.rm=FALSE )
  total <- length(pw)
  cat(sprintf("  %s: %d/%d match (%.1f%%)\n", p, match_count, total, 100*match_count/total))
}

## ---------------------------------------------------------------
## 6. Summary
## ---------------------------------------------------------------
cat("\n=== SUMMARY (median seconds) ===\n")
cat(sprintf("  proto batch IN():     %.4f s\n", median(proto_times)))
cat(sprintf("  proto single-probe:   %.4f s\n", median(single_times)))
cat(sprintf("  gitr parallel (6w):   %.4f s\n", median(gitr_times)))
cat(sprintf("  gitr sequential:      %.4f s\n", median(gitr_seq_times)))
cat(sprintf("  Speedup (proto batch vs gitr parallel): %.1fx\n",
            median(gitr_times) / median(proto_times)))
