################################################################
## TMB (Tumor Mutation Burden)
## Computed as log10(1 + non-silent mutation count) per sample.
##
## Universe of TMB = samples exome-sequenced in MC3 (mutationsamples view).
## Any tested-but-zero-mutation sample gets value=0 (defensive — doesn't
## currently occur in MC3 data, but ensures correctness if it ever does).

library(tidyverse)
source('tablemaker.R')

## "tested" universe = all samples in the MC3 MAF
exome_samples = dbGetQuery(con, 'SELECT DISTINCT sample FROM mutation')

## count non-silent mutations per sample from the raw MAF
mut_counts = dbGetQuery(con, '
  SELECT sample, count(*) as cnt
  FROM mutation
  GROUP BY sample
')

## left-join: any exome_sample without mutations gets cnt = 0
tmb_data = exome_samples %>%
  left_join(mut_counts, by = "sample") %>%
  mutate(cnt = ifelse(is.na(cnt), 0, cnt)) %>%
  mutate(value = log10(cnt + 1)) %>%
  mutate(probe = "tmb", type = "tmb") %>%
  select(sample, probe, value, type)

## diagnostic reporting
cat("\n=== TMB build summary ===\n")
cat("Exome-sequenced samples:", nrow(exome_samples), "\n")
cat("Samples with TMB value:", nrow(tmb_data), "\n")
cat("Of which: zero mutations:", sum(tmb_data$value == 0), "\n")
cat("\nMutation count distribution:\n")
print(summary(10^tmb_data$value - 1))

## coverage report: non-normal samples without TMB (informational, not error)
clinpheno_samples = dbGetQuery(con,
  'SELECT sample, tumtype, sample_type FROM clinpheno
   WHERE sample_type != "Solid Tissue Normal" OR sample_type IS NULL')
missing = clinpheno_samples %>% anti_join(tmb_data, by = "sample")
cat(sprintf("\nNon-normal samples WITHOUT TMB: %d (not exome-sequenced in MC3)\n",
            nrow(missing)))
if (nrow(missing) > 0) {
  cat("Top cohorts missing exome-seq:\n")
  print(missing %>% count(tumtype, sort = TRUE) %>% head(10))
}

tablemaker(tmb_data, suffix = FALSE, deleteType = TRUE)
