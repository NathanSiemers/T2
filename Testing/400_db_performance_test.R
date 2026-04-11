################################################################
## Database performance benchmark
## Tests query speed for different probe counts and data types
## Outputs: Testing/performance_log.csv (appended)
##          Testing/latest_performance_report.md (overwritten)

library(DBI)

dbfile = "tcga.db"
con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile, flags = RSQLite::SQLITE_RO)

iterations = 6
probe_counts = c(1, 3, 10, 30, 100, 300)
run_timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S")

cat(sprintf("=== DB Performance Benchmark: %s ===\n", run_timestamp))
cat(sprintf("Database: %s (%.1f GB)\n", dbfile, file.info(dbfile)$size / 1e9))
cat(sprintf("Iterations per test: %d\n\n", iterations))

## get all probes by type for sampling
all_probes = dbGetQuery(con, "SELECT p.probe, pt.type FROM probes p JOIN probe_types pt ON p.key = pt.probekey")
all_probes_cat = dbGetQuery(con, "SELECT p.probe, pt.type FROM probes p JOIN probe_types_cat pt ON p.key = pt.probekey")
types_num = sort(unique(all_probes$type))
types_cat = sort(unique(all_probes_cat$type))

results = data.frame(
  timestamp = character(),
  test = character(),
  detail = character(),
  n_probes = integer(),
  iteration = integer(),
  seconds = numeric(),
  rows_returned = integer(),
  stringsAsFactors = FALSE
)

## helper: benchmark a query
bench = function(query_fn, label, detail, n_probes, iters = iterations) {
  cat(sprintf("  %-45s ", paste0(label, " (", detail, ")")))
  times = numeric(iters)
  rows = integer(iters)
  for (i in seq_len(iters)) {
    t0 = proc.time()["elapsed"]
    r = query_fn()
    t1 = proc.time()["elapsed"]
    times[i] = t1 - t0
    rows[i] = if (is.data.frame(r)) nrow(r) else 0
  }
  med = median(times)
  cat(sprintf("median: %6.3fs  range: [%5.3f - %5.3f]  rows: %d\n", med, min(times), max(times), rows[1]))
  data.frame(
    timestamp = run_timestamp,
    test = rep(label, iters),
    detail = rep(detail, iters),
    n_probes = rep(n_probes, iters),
    iteration = seq_len(iters),
    seconds = times,
    rows_returned = rows,
    stringsAsFactors = FALSE
  )
}

################################################################
## Test 1: probe count scaling on tcgas (numeric dense view)
cat("--- Probe count scaling (tcgas) ---\n")
rna_probes = all_probes$probe[all_probes$type == "rna"]
for (n in probe_counts) {
  results = rbind(results, bench(
    function() {
      sampled = sample(rna_probes, min(n, length(rna_probes)))
      probe_sql = paste(sprintf("'%s'", sampled), collapse = ", ")
      dbGetQuery(con, sprintf("SELECT sample, probe, value FROM tcgas WHERE probe IN (%s)", probe_sql))
    },
    "tcgas_probe_count", paste0(n, " rna probes"), n
  ))
}

################################################################
## Test 2: probe count scaling on tcgacats (categorical dense view)
cat("\n--- Probe count scaling (tcgacats) ---\n")
cat_probes = all_probes_cat$probe
for (n in c(1, 3, 10, 30)) {
  results = rbind(results, bench(
    function() {
      sampled = sample(cat_probes, min(n, length(cat_probes)))
      probe_sql = paste(sprintf("'%s'", sampled), collapse = ", ")
      dbGetQuery(con, sprintf("SELECT sample, probe, value FROM tcgacats WHERE probe IN (%s)", probe_sql))
    },
    "tcgacats_probe_count", paste0(n, " cat probes"), n
  ))
}

################################################################
## Test 3: query by type on tcgas (smaller types only)
cat("\n--- Query by type (tcgas, small types) ---\n")
small_num_types = c("sig", "immune_score", "hrd", "estimate", "msi", "tmb", "rppa", "rabit")
small_num_types = intersect(small_num_types, types_num)
for (tp in small_num_types) {
  n_probes_type = sum(all_probes$type == tp)
  results = rbind(results, bench(
    function() {
      dbGetQuery(con, sprintf("SELECT sample, probe, value FROM tcgas WHERE type = '%s'", tp))
    },
    "tcgas_by_type", tp, n_probes_type
  ))
}

################################################################
## Test 4: query by type on tcgacats
cat("\n--- Query by type (tcgacats) ---\n")
small_cat_types = intersect(types_cat, c("molec_subtype", "immune_subtype", "muttest"))
for (tp in small_cat_types) {
  n_probes_type = sum(all_probes_cat$type == tp)
  results = rbind(results, bench(
    function() {
      dbGetQuery(con, sprintf("SELECT sample, probe, value FROM tcgacats WHERE type = '%s'", tp))
    },
    "tcgacats_by_type", tp, n_probes_type
  ))
}

################################################################
## Test 5: mixed probe query (numeric + categorical, like gitr does)
cat("\n--- Mixed probe queries (gitr-like) ---\n")
mixed_probes = c("CD8A", "FOXP3", "TP53.mut", "KRAS.cnc", "cohort", "sample_type")
for (n in c(3, 6)) {
  probes_to_use = mixed_probes[1:n]
  results = rbind(results, bench(
    function() {
      probe_sql = paste(sprintf("'%s'", probes_to_use), collapse = ", ")
      r1 = dbGetQuery(con, sprintf("SELECT sample, probe, value FROM tcgas WHERE probe IN (%s)", probe_sql))
      r2 = dbGetQuery(con, sprintf("SELECT sample, probe, value FROM tcgacats WHERE probe IN (%s)", probe_sql))
      rbind(r1, r2)
    },
    "mixed_num_cat", paste(probes_to_use, collapse = "+"), n
  ))
}

################################################################
## Test 6: DISTINCT probe lookup (used for finding which view has a probe)
cat("\n--- DISTINCT probe lookup ---\n")
for (n in c(10, 100, 300)) {
  results = rbind(results, bench(
    function() {
      sampled = sample(rna_probes, min(n, length(rna_probes)))
      probe_sql = paste(sprintf("'%s'", sampled), collapse = ", ")
      dbGetQuery(con, sprintf("SELECT DISTINCT probe FROM tcgas WHERE probe IN (%s)", probe_sql))
    },
    "distinct_probe_lookup", paste0(n, " probes"), n
  ))
}

dbDisconnect(con)

################################################################
## Save results

csv_file = "Testing/performance_log.csv"
if (file.exists(csv_file)) {
  existing = read.csv(csv_file, stringsAsFactors = FALSE)
  combined = rbind(results, existing)
} else {
  combined = results
}
write.csv(combined, csv_file, row.names = FALSE)
cat(sprintf("\nResults appended to %s (%d total rows)\n", csv_file, nrow(combined)))

################################################################
## Generate markdown report for this run

## summarize by test + detail
library(dplyr)
summary_df = results %>%
  group_by(test, detail, n_probes) %>%
  summarize(
    median_s = median(seconds),
    min_s = min(seconds),
    max_s = max(seconds),
    rows = first(rows_returned),
    .groups = "drop"
  ) %>%
  arrange(test, n_probes)

md_lines = c(
  sprintf("# Database Performance Report"),
  sprintf(""),
  sprintf("**Date:** %s", run_timestamp),
  sprintf("**Database:** %s (%.1f GB)", dbfile, file.info(dbfile)$size / 1e9),
  sprintf("**Iterations:** %d per test", iterations),
  sprintf("")
)

## group by test type
for (tname in unique(summary_df$test)) {
  sub = summary_df[summary_df$test == tname, ]
  md_lines = c(md_lines,
    sprintf("## %s", tname),
    "",
    "| Detail | Probes | Median (s) | Min (s) | Max (s) | Rows |",
    "|--------|-------:|-----------:|--------:|--------:|-----:|"
  )
  for (i in seq_len(nrow(sub))) {
    md_lines = c(md_lines, sprintf("| %s | %d | %.3f | %.3f | %.3f | %s |",
      sub$detail[i], sub$n_probes[i], sub$median_s[i], sub$min_s[i], sub$max_s[i],
      formatC(sub$rows[i], format = "d", big.mark = ",")))
  }
  md_lines = c(md_lines, "")
}

writeLines(md_lines, "Testing/latest_performance_report.md")
cat(sprintf("Report written to Testing/latest_performance_report.md\n"))
cat("\nDone.\n")
