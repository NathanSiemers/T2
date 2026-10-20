## TCGA/write_tcga_meta.R
## ============================================================================
## Writes the TCGA dataset's self-description into tcga.db: the dataset_meta table (roles,
## defaults, title/label, tte_variables, about, citation, attribution, about_url) and the
## types.label words, as the dataset contract asks (T2Mobile/docs/DATASET-CONTRACT.md).
## The role/default/title values are the ones of dataset_registry.R (.TCGA_*); they live in the
## file now so that the service and the apps read them from it, not from code.
##
##   Rscript TCGA/write_tcga_meta.R [db]       db: path (default ../tcga.db relative to TCGA/; TCGA.db works the same)
##   source("write_tcga_meta.R"); write_tcga_meta("../tcga.db.building")   (00-master.R does this)
##
## IDEMPOTENT: every key is replaced, the table / column are created when missing, one short
## write transaction. Refuses any path under /scratch/shinyusb (served files: deploy by a new
## directory / atomic mv, never by writing to a served file).
## ============================================================================
suppressMessages({ library(DBI); library(RSQLite); library(jsonlite) })
.wtm_root <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  cand <- c(if (length(fa)) dirname(dirname(normalizePath(sub("^--file=", "", fa[1])))), "..", ".")
  Filter(function(d) file.exists(file.path(d, "t2_build_lib.R")), cand)[1]
})
if (!exists("set_t2_sparse")) source(file.path(.wtm_root, "t2_views.R"))
if (!exists("t2_write_meta")) source(file.path(.wtm_root, "t2_build_lib.R"))

## TCGA/references.json: next to this script (Rscript, or source() from 00-master.R in TCGA/ or the repo root)
.tcga_references_file <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  of <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  cand <- c(if (length(fa)) dirname(normalizePath(sub("^--file=", "", fa[1]))), if (is.character(of)) dirname(normalizePath(of)),
            file.path(.wtm_root, "TCGA"), ".", "TCGA")
  f <- file.path(cand, "references.json"); f <- f[file.exists(f)]
  if (!length(f)) stop("TCGA/references.json not found (looked in: ", paste(unique(cand), collapse = ", "), ")")
  f[1]
}

.tcga_meta_values <- function() {
  tte <- function(nm, label, desc) t2_tte(nm, label, nm, paste0(nm, ".time"), "days", desc)
  cdr <- "TCGA Clinical Data Resource (Liu et al. 2018, Cell 173:400-416, PMID 29625055)"
  tte_list <- list(
    tte("OS",  "Overall Survival",
        paste0("Time from diagnosis to death from any cause; event 1 = death, 0 = censored at last contact. ", cdr, ".")),
    tte("PFI", "Progression-Free Interval",
        paste0("Time to a new tumor event (progression, local recurrence, distant metastasis, new primary tumor of the same cancer, or death with tumor); event 1 = occurred, 0 = censored. ", cdr, ".")),
    tte("DSS", "Disease-Specific Survival",
        paste0("Time to death from the cancer (deaths from other causes are censored); event 1 = cancer death, 0 = censored. ", cdr, ".")),
    tte("DFI", "Disease-Free Interval",
        paste0("Time to a new tumor event in patients who were disease-free after initial treatment; event 1 = occurred, 0 = censored. ", cdr, ".")))
  about <- paste(
    "T2 is a database and plotting tool for large tumor-profiling compendia. This dataset is the TCGA Pan-Cancer 2018 release (33 cancer types, about 11,000 patients):",
    "every measurement (expression, mutation, copy number, signatures, clinical annotation, survival) is stored per sample, so any variable can be plotted against any other.",
    "Survival endpoints (OS, PFI, DSS, DFI) are clinical columns, each an event indicator (1 = event, 0 = censored) with its time in days (OS.time, PFI.time, DSS.time, DFI.time);",
    "selecting one as the X variable switches the scatter plot to a Kaplan-Meier analysis of the Y marker in tertiles, with log-rank p-value and Cox hazard ratio.",
    "Survival data are from Liu et al. 2018, An Integrated TCGA Pan-Cancer Clinical Data Resource (Cell 173:400-416, PMID 29625055).")
  list(
    tte = tte_list,
    meta = list(
      title = "T2: TCGA 2018 Pan-Cancer Database", label = "TCGA Pan-Cancer 2018",
      cohort_col = "tumtype", subtype_col = "Subtype_Selected", sampletype_col = "sample_type",
      normal_label = "Solid Tissue Normal", heme_values = c("LAML", "THYM", "DLBC"),
      sampletype_levels = c("Primary Tumor", "Recurrent Tumor", "Metastatic", "Additional - New Primary",
                            "Additional Metastatic", "Primary Blood Derived Cancer - Peripheral Blood",
                            "Solid Tissue Normal"),
      default_x = "cohort", default_y = "CD8A", default_color = "sample_type", default_size = "",
      default_condition = "StromalScore.estimate",
      default_cohorts = c("COAD", "ESCA", "HNSC", "KIRC", "LUAD", "LUSC", "PAAD", "SKCM", "STAD"),
      order = 1L, about = about, references = t2_references_json(.tcga_references_file()),
      citation = paste("Liu J et al. An Integrated TCGA Pan-Cancer Clinical Data Resource to Drive High-Quality Survival Outcome Analytics. Cell 2018;173:400-416 (PMID 29625055).",
                       "Hoadley KA et al. Cell-of-Origin Patterns Dominate the Molecular Classification of 10,000 Tumors from 33 Types of Cancer. Cell 2018;173:291-304 (TCGA Pan-Cancer Atlas 2018)."),
      attribution = "The results here are in whole or part based upon data generated by the TCGA Research Network: https://www.cancer.gov/tcga",
      about_url = "https://gdc.cancer.gov/about-data/publications/pancanatlas"),
    ## the word a plot title uses for the type; "" for a bare name (CD8A, tmb)
    labels = c(rna = "", cnv = "CNA", cnc = "copy number class", rppa = "protein (RPPA)", mut = "mutation",
               viral = "viral reads", urna = "microRNA", pc_gene_program = "gene program", rabit = "TF activity",
               hrd = "HRD", immune_score = "immune score", molec_subtype = "molecular subtype",
               immune_subtype = "immune subtype", fmut = "mutation", muttest = "mutation", tmb = "",
               estimate = "ESTIMATE", msi = "MSI", sig = "signature"))
}

write_tcga_meta <- function(db) {
  if (grepl("^/scratch/shinyusb(/|$)", db) || grepl("^/scratch/shinyusb(/|$)", normalizePath(db, mustWork = FALSE)))
    stop("refusing a served path: ", db)
  if (!file.exists(db)) stop("no such file: ", db)
  v <- .tcga_meta_values()
  con <- DBI::dbConnect(RSQLite::SQLite(), db)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbExecute(con, "PRAGMA busy_timeout = 60000")
  types <- DBI::dbGetQuery(con, "SELECT type FROM types")$type
  unk <- setdiff(types, names(v$labels))
  if (length(unk)) stop("no label chosen for type(s): ", paste(unk, collapse = ", "))
  t2_write_meta(con, meta = v$meta, tte = v$tte)
  ## only the label: description, key, r_datatype and sparse are the build's (040/130/... and tablemaker)
  t2_write_types(con, data.frame(type = types, label = unname(unlist(v$labels[types])), stringsAsFactors = FALSE), allow_new = FALSE)
  message(sprintf("write_tcga_meta: %d dataset_meta keys, %d type labels -> %s", length(v$meta) + 1L, length(types), db))
  invisible(TRUE)
}

.wtm_direct <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  length(fa) && identical(basename(sub("^--file=", "", fa[1])), "write_tcga_meta.R")
}
if (.wtm_direct()) {
  a <- commandArgs(trailingOnly = TRUE)
  here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
  db <- if (length(a) >= 1) a[1] else file.path(here, "..", "tcga.db")
  write_tcga_meta(db)
}
