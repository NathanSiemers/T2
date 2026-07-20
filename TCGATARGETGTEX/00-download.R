## TCGATARGETGTEX/00-download.R
## ============================================================================
## Download the UCSC Xena "TCGA TARGET GTEx" (Toil RSEM recompute) source files
## needed to build datasets/tcgatargetgtex.db. Idempotent: skips a file that is
## already present at the expected byte size.
##
## Files (UCSC Toil hub, https://xenabrowser.net , cohort "TCGA TARGET GTEx"):
##   * gene-level RSEM TPM expression  (Ensembl ids, log2(tpm+0.001))
##   * sample phenotype / annotation   (study, disease, sample type, ...)
##   * gencode.v23 gene probemap       (Ensembl id -> HGNC symbol, coords)
## ============================================================================

ttg_dir <- function() {
  here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) NA)
  if (is.na(here)) here <- "TCGATARGETGTEX"
  here
}
DATADIR <- file.path(ttg_dir(), "Data")
dir.create(DATADIR, showWarnings = FALSE, recursive = TRUE)

BASE <- "https://toil-xena-hub.s3.us-east-1.amazonaws.com/download"

## name = local filename, url = remote, size = expected bytes (sanity check)
FILES <- list(
  list(name = "TcgaTargetGtex_rsem_gene_tpm.gz",
       url  = paste0(BASE, "/TcgaTargetGtex_rsem_gene_tpm.gz"),
       size = 1323254426),
  list(name = "TcgaTargetGTEX_phenotype.txt.gz",
       url  = paste0(BASE, "/TcgaTargetGTEX_phenotype.txt.gz"),
       size = 135753),
  list(name = "gencode.v23.annotation.gene.probemap",
       url  = paste0(BASE, "/probeMap%2Fgencode.v23.annotation.gene.probemap"),
       size = 3244244)
)

options(timeout = max(3600, getOption("timeout")))

for (f in FILES) {
  dest <- file.path(DATADIR, f$name)
  if (file.exists(dest) && file.info(dest)$size == f$size) {
    cat(sprintf("[skip] %s already present (%d bytes)\n", f$name, f$size))
    next
  }
  cat(sprintf("[get ] %s -> %s\n", f$url, dest))
  utils::download.file(f$url, dest, mode = "wb", quiet = FALSE)
  got <- file.info(dest)$size
  if (!is.na(f$size) && got != f$size)
    warning(sprintf("%s: downloaded %d bytes, expected %d", f$name, got, f$size))
  cat(sprintf("[done] %s (%d bytes)\n", f$name, got))
}

cat("All TCGA-TARGET-GTEX source files present in", DATADIR, "\n")
