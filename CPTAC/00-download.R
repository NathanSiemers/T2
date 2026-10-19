## CPTAC/00-download.R
## ============================================================================
## Download the open CPTAC Pan-Cancer harmonized data freeze needed to build the
## CPTAC dataset. Idempotent: a file already present whose size equals the size
## recorded in Data/downloaded_sizes.tsv (written on first download) is skipped.
##
## 1. PDC pan-cancer files (https://pdc.cancer.gov, no login):
##      listing  POST /graphql  getAllUIPancancerFiles  (file_size is null in the
##               API, so the manifest records the downloaded byte size)
##      download GET  /pdcapi/file/signedURLFromUuid/<file_id>  -> signed URL
##    -> Data/pdc_pancancer_files.tsv (full listing) and the wanted zips, each
##       unzipped into Data/<zipname-without-.zip>/
## 2. LinkedOmicsKB mirror of the same freeze (S3, no login): per cohort the
##    RNA TPM file, survival, phenotype, meta, case lists. Names are discovered
##    from https://kb.linkedomics.org/download (a static page listing the URLs).
## Downloaded files are untrusted data; they live only in CPTAC/Data/.
## Run (container): Rscript CPTAC/00-download.R   (from the repo root)
## ============================================================================
suppressMessages({library(jsonlite); library(httr2)})
here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) NA)
if (is.na(here)) {
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  here <- if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else "CPTAC"
}
DATADIR <- file.path(here, "Data")
dir.create(DATADIR, showWarnings = FALSE, recursive = TRUE)
options(timeout = max(3600, getOption("timeout")))

COHORTS <- c("BRCA","CCRCC","COAD","GBM","HNSCC","LSCC","LUAD","OV","PDAC","UCEC")
WANTED_ZIPS <- c("Proteome_BCM_GENCODE_v34_harmonized_v1.zip",
                 "Phosphoproteome_BCM_GENCODE_v34_harmonized_v1.zip",
                 "RNA_BCM_v1.zip", "CNV_BCM_v1.zip", "Mutation_BCM_v1.zip",
                 "Clinical_meta_data_v1.zip",
                 "CPTAC_pancancer_data_freeze_cohort_size.xlsx")
MIRROR_ROOT <- "https://cptac-pancancer-data.s3.us-west-2.amazonaws.com/"

## ---- size ledger ----------------------------------------------------------
LEDGER <- file.path(DATADIR, "downloaded_sizes.tsv")
ledger <- if (file.exists(LEDGER)) read.delim(LEDGER, stringsAsFactors = FALSE) else
  data.frame(name = character(), size = numeric(), stringsAsFactors = FALSE)
save_ledger <- function() write.table(ledger, LEDGER, sep = "\t", quote = FALSE, row.names = FALSE)
have <- function(rel) {
  p <- file.path(DATADIR, rel)
  file.exists(p) && any(ledger$name == rel & ledger$size == file.info(p)$size)
}
record <- function(rel) {
  sz <- file.info(file.path(DATADIR, rel))$size
  ledger <<- rbind(ledger[ledger$name != rel, ], data.frame(name = rel, size = sz))
  save_ledger(); sz
}
fetch <- function(url, rel) {
  if (have(rel)) { cat(sprintf("[skip] %s\n", rel)); return(invisible(TRUE)) }
  dest <- file.path(DATADIR, rel); dir.create(dirname(dest), FALSE, TRUE)
  tmp <- paste0(dest, ".part")
  cat(sprintf("[get ] %s\n", rel))
  ok <- tryCatch({ utils::download.file(url, tmp, mode = "wb", quiet = TRUE) == 0 },
                 error = function(e) { cat("   failed:", conditionMessage(e), "\n"); FALSE },
                 warning = function(w) { cat("   failed:", conditionMessage(w), "\n"); FALSE })
  if (!ok || !file.exists(tmp) || file.info(tmp)$size == 0) { unlink(tmp); return(invisible(FALSE)) }
  file.rename(tmp, dest); cat(sprintf("[done] %s (%d bytes)\n", rel, record(rel)))
  invisible(TRUE)
}

## ---- 1. PDC ----------------------------------------------------------------
q <- '{"query":"{getAllUIPancancerFiles{file_id file_name file_size file_type data_category downloadable description}}"}'
resp <- request("https://pdc.cancer.gov/graphql") |> req_body_raw(q, "application/json") |>
  req_retry(max_tries = 4) |> req_perform()
lst <- fromJSON(resp_body_string(resp))$data$getAllUIPancancerFiles
lst$description <- gsub("[\t\r\n]+", " ", lst$description)
mani <- file.path(DATADIR, "pdc_pancancer_files.tsv")
## sizes: keep what an earlier run recorded
lst$downloaded_bytes <- ledger$size[match(lst$file_name, ledger$name)]
sel <- lst[lst$file_name %in% WANTED_ZIPS, ]
missing_names <- setdiff(WANTED_ZIPS, lst$file_name)
if (length(missing_names)) cat("[note] not in PDC listing:", missing_names, "\n")

for (i in seq_len(nrow(sel))) {
  nm <- sel$file_name[i]
  if (!have(nm)) {
    su <- NULL
    for (k in 1:5) {
      r <- tryCatch(request(paste0("https://pdc.cancer.gov/pdcapi/file/signedURLFromUuid/", sel$file_id[i])) |>
                      req_retry(max_tries = 4) |> req_perform() |> resp_body_string(), error = function(e) NULL)
      su <- tryCatch(fromJSON(r), error = function(e) NULL)
      if (!is.null(su)) break; Sys.sleep(3)
    }
    url <- if (is.list(su) && is.character(su$data)) su$data else NULL
    if (is.null(url)) { cat("[fail] no signed URL for", nm, "\n"); next }
    fetch(url, nm)
  } else cat(sprintf("[skip] %s\n", nm))
  if (grepl("\\.zip$", nm) && have(nm)) {
    d <- file.path(DATADIR, sub("\\.zip$", "", nm))
    if (!dir.exists(d) || !length(list.files(d))) {
      dir.create(d, FALSE, TRUE); utils::unzip(file.path(DATADIR, nm), exdir = d)
      cat("[unzip]", nm, "\n")
    }
  }
}
lst$downloaded_bytes <- ledger$size[match(lst$file_name, ledger$name)]
write.table(lst, mani, sep = "\t", quote = FALSE, row.names = FALSE, na = "")
cat("[manifest]", mani, nrow(lst), "files listed\n")

## ---- 2. LinkedOmicsKB mirror ---------------------------------------------
page <- paste(readLines("https://kb.linkedomics.org/download", warn = FALSE), collapse = "\n")
urls <- unique(regmatches(page, gregexpr("https://cptac-pancancer-data[^\"' <>]*", page))[[1]])
writeLines(urls, file.path(DATADIR, "linkedomics_urls.txt"))
cat("[mirror] page lists", length(urls), "urls\n")
for (co in COHORTS) {
  pat <- paste0("/(", co, "-gene_TPM[^/]*|", co, "/", co,
                "_(meta|survival|phenotype|Tumor_CaseList|Normal_CaseList)\\.txt)$")
  u <- grep(pat, urls, value = TRUE)
  if (!any(grepl("gene_TPM", u))) cat("[WARN] no TPM url for", co, "\n")
  for (x in u) {
    rel <- file.path("mirror", co, basename(utils::URLdecode(x)))
    fetch(x, rel)
  }
}
cat("Done. Files in", DATADIR, "\n")
