## Test that UCSCXenaTools can still download TCGA data
## Downloads just the RNA-seq file to a temp directory and reports success/failure
## Run from the T2 project root: Rscript Testing/test_download.R

cat("=== Testing UCSCXenaTools download ===\n\n")

## Install if needed, then load
if (!require('UCSCXenaTools', quietly = TRUE)) {
  cat("UCSCXenaTools not found, installing...\n")
  install.packages('UCSCXenaTools', repos = 'https://cloud.r-project.org')
  if (!require('UCSCXenaTools', quietly = TRUE)) {
    cat("FAIL: UCSCXenaTools could not be installed\n")
    quit(status = 1)
  }
}
cat("UCSCXenaTools version:", as.character(packageVersion("UCSCXenaTools")), "\n")

## Show what's available for PANCAN
cat("\n=== Available PANCAN data ===\n")
pancan = showTCGA(project = "PANCAN")
print(pancan)

## Create temp directory
tmpdir = tempfile("xena_test_")
dir.create(tmpdir)
cat("\nDownload directory:", tmpdir, "\n\n")

## Download the RNA-seq file (batch-effects normalized)
## This is the file used by 070-rna.R:
##   EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz
cat("Attempting to download PANCAN RNA-seq (batch effects normalized)...\n")
t0 = proc.time()["elapsed"]

result = tryCatch({
  downloadTCGA(
    project = "PANCAN",
    data_type = "Gene Expression RNASeq",
    file_type = "Batch effects normalized",
    trans_slash = TRUE,
    force = TRUE,
    destdir = tmpdir,
    method = 'auto'
  )
  TRUE
}, error = function(e) {
  cat("ERROR:", e$message, "\n")
  FALSE
})

elapsed = proc.time()["elapsed"] - t0

files = list.files(tmpdir, recursive = TRUE)
if (length(files) > 0) {
  cat("\nDownloaded files:\n")
  for (f in files) {
    fpath = file.path(tmpdir, f)
    fsize = file.info(fpath)$size
    cat(sprintf("  %s (%.1f MB)\n", f, fsize / 1e6))
  }

  ## Verify content is readable
  gz_files = list.files(tmpdir, pattern = "\\.gz$", full.names = TRUE, recursive = TRUE)
  if (length(gz_files) > 0) {
    tryCatch({
      con = gzfile(gz_files[1])
      head_lines = readLines(con, n = 2)
      close(con)
      ncols = length(strsplit(head_lines[1], "\t")[[1]])
      cat(sprintf("\nFile has %d columns (samples) on header line\n", ncols))
    }, error = function(e) {
      cat("WARNING: could not read downloaded file:", e$message, "\n")
    })
  }

  cat(sprintf("\nPASS: Download succeeded in %.0f seconds\n", elapsed))
} else {
  cat(sprintf("\nFAIL: No files downloaded after %.0f seconds\n", elapsed))
  cat("The UCSCXenaTools API may have changed.\n")
  cat("Check: showTCGA(project = 'PANCAN') for current data types.\n")
}

## Cleanup
unlink(tmpdir, recursive = TRUE)
cat("Temp directory cleaned up.\n")
