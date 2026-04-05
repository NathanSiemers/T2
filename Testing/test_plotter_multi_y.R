## Test suite for multi_y and zscore_y plotter features
## Run from the T2 project root: Rscript Testing/test_plotter_multi_y.R

library(RSQLite)
con = dbConnect(SQLite(), "tcga.db", flags = SQLITE_RO)
source("database_connection_shiny.R")
source("lib.R")

outdir = "Testing"

## Test 1: categorical x, multiple y, multi_y=TRUE
## Expected: grouped boxplots with each probe as a different color
cat("=== Test 1: categorical x + multi_y ===\n")
p1 = plotter(x = "cohort", y = c("FOXP3", "CD8A", "CCR8"), multi_y = TRUE,
             cohort = c("BRCA", "LUAD", "SKCM"), alpha = 0.3, ncols = 3)
ggsave(file.path(outdir, "test_multi_y_categorical.png"), p1, width = 12, height = 6)
cat("Saved test_multi_y_categorical.png\n")

## Test 2: continuous x, multiple y, multi_y=TRUE
## Expected: auto-faceted by probe, each in its own panel
cat("\n=== Test 2: continuous x + multi_y ===\n")
p2 = plotter(x = "CD8A", y = c("FOXP3", "CCR8", "CD3E"), multi_y = TRUE,
             nonormal = TRUE, alpha = 0.1)
ggsave(file.path(outdir, "test_multi_y_continuous.png"), p2, width = 14, height = 6)
cat("Saved test_multi_y_continuous.png\n")

## Test 3: single y, multi_y=TRUE (should behave like normal single-y plot)
cat("\n=== Test 3: single y + multi_y (no-op) ===\n")
p3 = plotter(x = "cohort", y = "FOXP3", multi_y = TRUE,
             cohort = c("BRCA", "LUAD"), alpha = 0.3)
ggsave(file.path(outdir, "test_multi_y_single.png"), p3, width = 8, height = 6)
cat("Saved test_multi_y_single.png\n")

## Test 4: multi_y=FALSE (original median-Z signature behavior)
cat("\n=== Test 4: multi_y=FALSE (median-Z signature) ===\n")
p4 = plotter(x = "cohort", y = c("FOXP3", "CD8A", "CCR8"), multi_y = FALSE,
             cohort = c("BRCA", "LUAD", "SKCM"), alpha = 0.3)
ggsave(file.path(outdir, "test_multi_y_combined.png"), p4, width = 8, height = 6)
cat("Saved test_multi_y_combined.png\n")

## Test 5: multi_y + zscore_y with probes of very different magnitudes
## Expected: all probes centered around 0 on same scale
cat("\n=== Test 5: multi_y + zscore_y ===\n")
p5 = plotter(x = "cohort", y = c("FOXP3", "StromalScore.estimate", "HRD.hrd"),
             multi_y = TRUE, zscore_y = TRUE,
             cohort = c("BRCA", "LUAD", "SKCM"), alpha = 0.3, ncols = 3)
ggsave(file.path(outdir, "test_zscore_y.png"), p5, width = 12, height = 6)
cat("Saved test_zscore_y.png\n")

## Test 6: zscore_y without multi_y (single probe, should still z-score)
cat("\n=== Test 6: zscore_y single probe ===\n")
p6 = plotter(x = "cohort", y = "StromalScore.estimate", zscore_y = TRUE,
             cohort = c("BRCA", "LUAD"), alpha = 0.3)
ggsave(file.path(outdir, "test_zscore_y_single.png"), p6, width = 8, height = 6)
cat("Saved test_zscore_y_single.png\n")

dbDisconnect(con)
cat("\nAll tests complete.\n")
