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

## Create temp directory
tmpdir = tempfile("xena_test_")
dir.create(tmpdir)
cat("Download directory:", tmpdir, "\n\n")

## Try downloading just the RNA-seq file (EB++AdjustPANCAN)
cat("Attempting to download PANCAN RNA-seq data...\n")
t0 = proc.time()["elapsed"]

result = tryCatch({
  downloadTCGA(
    project = "PANCAN",
    data_type = "Gene Expression RNASeq",
    file_type = "IlluminaHiSeq",
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

if (result) {
  files = list.files(tmpdir, recursive = TRUE)
  cat("\nDownloaded files:\n")
  for (f in files) {
    fpath = file.path(tmpdir, f)
    fsize = file.info(fpath)$size
    cat(sprintf("  %s (%.1f MB)\n", f, fsize / 1e6))
  }

  ## Check that at least one file has real content
  gz_files = list.files(tmpdir, pattern = "\\.gz$", full.names = TRUE, recursive = TRUE)
  if (length(gz_files) > 0) {
    ## Try reading first few lines
    test_read = tryCatch({
      head_lines = readLines(gzfile(gz_files[1]), n = 3)
      cat(sprintf("\nFirst file has %d header chars\n", nchar(head_lines[1])))
      TRUE
    }, error = function(e) {
      cat("WARNING: could not read downloaded file:", e$message, "\n")
      FALSE
    })
  }

  cat(sprintf("\nPASS: Download succeeded in %.0f seconds\n", elapsed))
} else {
  cat(sprintf("\nFAIL: Download failed after %.0f seconds\n", elapsed))
}

## Cleanup
unlink(tmpdir, recursive = TRUE)
cat("Temp directory cleaned up.\n")
