################################################################
## MSI - Microsatellite Instability (MSIsensor scores)
## Source: Knijnenburg et al. 2018, Cell Reports (PMID 30625304)
##         Table S5 via Ding et al. 2018 supplementary
## MSIsensor score: 0 = microsatellite stable, higher = more unstable
##   Typical MSI-H threshold: >= 3.5 or >= 10 depending on study

library(readxl)

msi_file = 'Data/Knijnenburg_TableS5_MSIsensor.xlsx'

## Download if not present
if (!file.exists(msi_file)) {
  cat("Downloading Knijnenburg Table S5 (MSIsensor scores)...\n")
  download.file(
    url = "https://www.cell.com/cms/10.1016/j.celrep.2018.12.060/attachment/586e3aa7-7445-4406-b3e8-42768e07b554/mmc6.xlsx",
    destfile = msi_file,
    mode = "wb"
  )
}

## Read the Excel file (skip 2 header rows)
msi_raw = read_excel(msi_file, sheet = 1, skip = 2,
                     col_names = c("patient", "MSIsensor_score", "MSI_gene_mutation"))
msi_raw = msi_raw[!is.na(msi_raw$patient) & msi_raw$patient != "Participant Barcode", ]
msi_raw$MSIsensor_score = as.numeric(msi_raw$MSIsensor_score)

cat("MSI raw data:", nrow(msi_raw), "patients\n")
cat("Score range:", range(msi_raw$MSIsensor_score, na.rm = TRUE), "\n")
cat("NAs in score:", sum(is.na(msi_raw$MSIsensor_score)), "\n")

## Get non-normal samples from clinpheno
clin_samples = dbGetQuery(con, "
  SELECT sample FROM clinpheno
  WHERE sample_type IS NOT NULL
  AND sample_type <> 'Solid Tissue Normal'
")
clin_samples$patient = substr(clin_samples$sample, 1, 12)

cat("Non-normal samples in DB:", nrow(clin_samples), "\n")

## Join: patient barcode match, keep only non-normal samples
my_msi = merge(clin_samples, msi_raw[, c("patient", "MSIsensor_score")], by = "patient")
my_msi = my_msi[!is.na(my_msi$MSIsensor_score), ]

cat("Matched tumor samples with MSI scores:", nrow(my_msi), "\n")

## Reshape to tidy format: sample, probe, value, type
my_msi = data.frame(
  sample = my_msi$sample,
  probe  = "MSIsensor_score",
  value  = my_msi$MSIsensor_score,
  type   = "msi",
  stringsAsFactors = FALSE
)

head(my_msi)
cat("Unique samples:", length(unique(my_msi$sample)), "\n")

tablemaker(my_msi)

my_msi = NULL; gc()
