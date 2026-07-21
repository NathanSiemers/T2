## TCGATARGETGTEX/build_tcgatargetgtex.R
## ============================================================================
## Build datasets/tcgatargetgtex.db -- the UCSC Xena "TCGA TARGET GTEx" (Toil
## RSEM recompute) RNA-seq dataset in the T2 schema shape, so the T2 Shiny app
## can serve it alongside tcga.db (see MULTIDATASET.md).
##
## WHAT THIS DATASET IS
##   ~19,131 samples (TCGA 10,535 / GTEX 7,862 / TARGET 734), all RNA-seq'd
##   through ONE identical Toil pipeline => internally comparable across the
##   three studies. Clinical annotation is intentionally light: study, disease,
##   primary_site, detailed_category, sample_type, gender.
##
## EXPRESSION HANDLING (the only "real" data type here)
##   Source: TcgaTargetGtex_rsem_gene_tpm  (Ensembl gene ids, log2(tpm+0.001)).
##   * Ensembl -> HGNC symbol via gencode.v23 probemap (../ensembl_to_hgnc.R).
##   * genes sharing a symbol are summed IN LINEAR SPACE (unlog->add->relog).
##   * Ensembl ids mapping to >1 symbol are dropped; ids with no symbol kept.
##   * OUTPUT unit is log2(tpm+1): unexpressed genes (tpm 0) become exactly 0,
##     so they collapse into the T2 sparse-zero model (stored implicitly, the
##     dense `tcgas` view reconstructs them as 0). This is what keeps the fact
##     table to a sane size.
##
## ROLE MAP (dataset_meta -> resolved by dataset_registry.R)
##   cohort  = disease   (primary disease or tissue; the tumtype analog)
##   subtype = study     (TCGA / TARGET / GTEX -- the "major cohort" handle)
##   sample_type with multi-value normal_label {Solid Tissue Normal, Normal
##   Tissue, Cell Line} so "Exclude Non-tumor" works across all three studies.
##
## RUN
##   Rscript TCGATARGETGTEX/00-download.R        # fetch sources (~1.3 GB)
##   Rscript TCGATARGETGTEX/build_tcgatargetgtex.R
## Fast smoke-build: env TTG_SUBSET_GENES=1000 TTG_SUBSET_SAMPLES=2000 and set
## TTG_OUT to a scratch path.
## ============================================================================

suppressMessages({
  library(DBI); library(RSQLite); library(data.table)
})

## --- locate project root (parent of this script's folder) -------------------
args0 <- commandArgs(trailingOnly = FALSE)
fa <- grep("^--file=", args0, value = TRUE)
script_path <- if (length(fa)) normalizePath(sub("^--file=", "", fa[1])) else
  normalizePath("TCGATARGETGTEX/build_tcgatargetgtex.R")
TTG_DIR  <- dirname(script_path)
ROOT     <- normalizePath(file.path(TTG_DIR, ".."))
DATADIR  <- file.path(TTG_DIR, "Data")
setwd(ROOT)

source(file.path(ROOT, "ensembl_to_hgnc.R"))
source(file.path(ROOT, "t2_views.R"))

## --- config -----------------------------------------------------------------
EXPR_GZ  <- file.path(DATADIR, "TcgaTargetGtex_rsem_gene_tpm.gz")
PHENO_GZ <- file.path(DATADIR, "TcgaTargetGTEX_phenotype.txt.gz")
PROBEMAP <- file.path(DATADIR, "gencode.v23.annotation.gene.probemap")

OUT <- Sys.getenv("TTG_OUT", file.path(ROOT, "datasets", "tcgatargetgtex.db"))
SUBSET_GENES   <- as.integer(Sys.getenv("TTG_SUBSET_GENES",   "0"))   # 0 = all
SUBSET_SAMPLES <- as.integer(Sys.getenv("TTG_SUBSET_SAMPLES", "0"))   # 0 = all
PROBE_CHUNK    <- as.integer(Sys.getenv("TTG_PROBE_CHUNK", "5000"))

stopifnot(file.exists(EXPR_GZ), file.exists(PHENO_GZ), file.exists(PROBEMAP))
dir.create(dirname(OUT), showWarnings = FALSE, recursive = TRUE)

t0 <- Sys.time()
say <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), ..., "\n")

## ============================================================================
## 1. Phenotype -> clinpheno (rename to T2-friendly column names)
## ============================================================================
say("reading phenotype:", PHENO_GZ)
ph <- fread(cmd = paste("zcat", shQuote(PHENO_GZ)), sep = "\t",
            header = TRUE, quote = "", na.strings = c("", "NA"))
ren <- c("sample"                    = "sample",
         "detailed_category"         = "detailed_category",
         "primary disease or tissue" = "disease",
         "_primary_site"             = "primary_site",
         "_sample_type"              = "sample_type",
         "_gender"                   = "gender",
         "_study"                    = "study")
setnames(ph, names(ren), ren, skip_absent = TRUE)
clinpheno <- as.data.frame(ph[, .(sample, study, disease, primary_site,
                                  detailed_category, sample_type, gender)])
clinpheno$sample <- as.character(clinpheno$sample)
say("phenotype rows:", nrow(clinpheno))

## ============================================================================
## 2. Ensembl -> HGNC map + expression matrix -> collapsed HGNC matrix
## ============================================================================
say("reading probemap:", PROBEMAP)
pm  <- fread(PROBEMAP, sep = "\t", header = TRUE)
map <- load_ensembl_hgnc_map(pm[, 1:2])

say("reading expression matrix (this is the big read):", EXPR_GZ)
nrows <- if (SUBSET_GENES > 0) SUBSET_GENES else Inf
expr <- fread(cmd = paste("zcat", shQuote(EXPR_GZ)), sep = "\t",
              header = TRUE, nrows = nrows)
setnames(expr, 1, "id")
say("expression matrix:", nrow(expr), "genes x", ncol(expr) - 1, "samples")

## restrict to samples that exist in BOTH expression and phenotype
samp_cols <- setdiff(names(expr), "id")
samp_cols <- intersect(samp_cols, clinpheno$sample)
if (SUBSET_SAMPLES > 0) samp_cols <- head(samp_cols, SUBSET_SAMPLES)
expr <- expr[, c("id", samp_cols), with = FALSE]
clinpheno <- clinpheno[clinpheno$sample %in% samp_cols, , drop = FALSE]
say("after sample intersection:", length(samp_cols), "samples")

say("collapsing Ensembl -> HGNC (unlog -> sum -> relog as log2(tpm+1)) ...")
coll <- collapse_ensembl_to_hgnc(expr, map,
                                 from_log = TRUE, log_base = 2,
                                 log_offset = 0.001, relog_offset = 1)
rm(expr); gc()
gene_probes <- coll$probe
say("collapsed probes:", length(gene_probes))

## ============================================================================
## 3. Dimension tables + empty fact tables
## ============================================================================
if (file.exists(OUT)) file.remove(OUT)
con <- dbConnect(SQLite(), OUT)

samples_tbl <- data.frame(key = seq_along(samp_cols), sample = samp_cols,
                          stringsAsFactors = FALSE)
probes_tbl  <- data.frame(key = seq_along(gene_probes), probe = gene_probes,
                          stringsAsFactors = FALSE)
clin_vars   <- c("study", "disease", "primary_site",
                 "detailed_category", "sample_type", "gender")
all_probes  <- c(gene_probes, clin_vars)
allprobes_tbl <- data.frame(key = seq_along(all_probes), probe = all_probes,
                            stringsAsFactors = FALSE)

types_tbl <- data.frame(
  key = 1L, type = "rna",
  description = "Gene-level RNA-seq expression, UCSC Toil RSEM recompute, collapsed Ensembl->HGNC, log2(TPM+1)",
  example     = "CD8A",
  reference   = "Vivian et al. Nat Biotechnol 2017; Goldman et al. Nat Biotechnol 2020 (UCSC Xena)",
  source_url  = "https://xenabrowser.net/datapages/?cohort=TCGA%20TARGET%20GTEx",
  source_file = "TcgaTargetGtex_rsem_gene_tpm.gz",
  stringsAsFactors = FALSE)
datatypes_tbl <- data.frame(type = "rna", r_datatype = "numeric",
                            stringsAsFactors = FALSE)

dbWriteTable(con, "samples",   samples_tbl,   overwrite = TRUE)
dbWriteTable(con, "probes",    probes_tbl,    overwrite = TRUE)
dbWriteTable(con, "allprobes", allprobes_tbl, overwrite = TRUE)
dbWriteTable(con, "types",     types_tbl,     overwrite = TRUE)
dbWriteTable(con, "datatypes", datatypes_tbl, overwrite = TRUE)
dbWriteTable(con, "clinpheno", clinpheno,     overwrite = TRUE)

## tested: every sample was RNA-seq'd
tested <- data.frame(sample = samp_cols, value = 1L, type = "rna",
                     stringsAsFactors = FALSE)
dbWriteTable(con, "tested", tested, overwrite = TRUE)

## empty fact tables with explicit schema (chunks append into tcgai)
dbExecute(con, "CREATE TABLE tcgai (samplekey INT, probekey INT, value FLOAT, type CHARACTER)")
dbExecute(con, "CREATE TABLE tcgacati (samplekey INT, probekey INT, value CHARACTER, type CHARACTER)")

## ============================================================================
## 4. Melt collapsed matrix -> long -> sparse-filter -> tcgai (chunked)
## ============================================================================
sample_key <- setNames(samples_tbl$key, samples_tbl$sample)
probe_key  <- setNames(probes_tbl$key,  probes_tbl$probe)
setDT(coll)
nprobe <- nrow(coll)
inserted <- 0L
say("inserting tcgai in probe-chunks of", PROBE_CHUNK, "...")
for (lo in seq(1, nprobe, by = PROBE_CHUNK)) {
  hi  <- min(lo + PROBE_CHUNK - 1L, nprobe)
  sub <- coll[lo:hi]
  long <- melt(sub, id.vars = "probe", variable.name = "sample",
               value.name = "value", variable.factor = FALSE)
  long <- long[value != 0]                       # sparse: drop unexpressed (==0)
  if (nrow(long)) {
    long[, samplekey := sample_key[sample]]
    long[, probekey  := probe_key[probe]]
    long[, type := "rna"]
    dbWriteTable(con, "tcgai",
                 long[, .(samplekey, probekey, value, type)], append = TRUE)
    inserted <- inserted + nrow(long)
  }
  say(sprintf("  probes %d-%d / %d  (tcgai rows so far: %d)", lo, hi, nprobe, inserted))
}
rm(coll); gc()
say("tcgai total rows:", inserted)

## ============================================================================
## 5. cohorts table (cohort = disease, labelled with its study)
## ============================================================================
## one row per disease, labelled with its study. Exclude samples with no
## disease (e.g. the single TCGA "Control Analyte") so the cohort dropdown gets
## no blank entry -- the sample itself is still kept in clinpheno/tested/views.
cdt <- as.data.table(clinpheno)[!is.na(disease) & nzchar(disease),
                                .(study = paste(sort(unique(study)), collapse = "/")),
                                by = disease]
cohorts_tbl <- data.frame(
  cohort       = cdt$disease,
  lcohort      = cdt$disease,
  cohortstring = sprintf("%s (%s)", cdt$disease, cdt$study),
  stringsAsFactors = FALSE)
cohorts_tbl <- cohorts_tbl[order(cohorts_tbl$cohort), ]
dbWriteTable(con, "cohorts", cohorts_tbl, overwrite = TRUE)
say("cohorts:", nrow(cohorts_tbl))

## ============================================================================
## 6. dataset_meta (self-describing role map; see dataset_registry.R)
## ============================================================================
dataset_meta <- data.frame(
  key = c("title", "label",
          "cohort_col", "subtype_col", "sampletype_col",
          "normal_label", "heme_values", "sampletype_levels",
          "default_x", "default_y", "default_color", "default_size",
          "default_condition"),
  value = c(
    "T2: TCGA-TARGET-GTEx (UCSC Toil RNA-seq)",
    "TCGA-TARGET-GTEx (Toil)",
    "disease", "study", "sample_type",
    "Solid Tissue Normal,Normal Tissue,Cell Line",
    paste("Acute Lymphoblastic Leukemia", "Acute Myeloid Leukemia",
          "Diffuse Large B-Cell Lymphoma", "Thymoma", "Whole Blood", "Spleen",
          "Cells - Ebv-Transformed Lymphocytes",
          "Cells - Leukemia Cell Line (Cml)", sep = ","),
    paste("Primary Tumor", "Primary Solid Tumor", "Recurrent Tumor",
          "Recurrent Solid Tumor", "Metastatic", "Additional Metastatic",
          "Additional - New Primary",
          "Primary Blood Derived Cancer - Peripheral Blood",
          "Primary Blood Derived Cancer - Bone Marrow",
          "Recurrent Blood Derived Cancer - Bone Marrow",
          "Recurrent Blood Derived Cancer - Peripheral Blood",
          "Post treatment Blood Cancer - Bone Marrow",
          "Post treatment Blood Cancer - Blood", "Control Analyte",
          "Cell Line", "Normal Tissue", "Solid Tissue Normal", sep = ","),
    "cohort", "CD8A", "study", "", ""),
  stringsAsFactors = FALSE)
dbWriteTable(con, "dataset_meta", dataset_meta, overwrite = TRUE)

## ============================================================================
## 7. probe_types + indexes + views (shared DDL from ../t2_views.R)
## ============================================================================
say("building probe_types, indexes, views ...")
finalize_t2_core(con)

## ============================================================================
## 8. summary
## ============================================================================
summ <- function(q) dbGetQuery(con, q)[1, 1]
cat("\n==================== BUILD SUMMARY ====================\n")
cat("db file        :", OUT, "\n")
cat("samples        :", summ("SELECT COUNT(*) FROM samples"), "\n")
cat("gene probes    :", summ("SELECT COUNT(*) FROM probes"), "\n")
cat("allprobes      :", summ("SELECT COUNT(*) FROM allprobes"), "\n")
cat("tcgai rows     :", summ("SELECT COUNT(*) FROM tcgai"), "\n")
cat("tcgacati rows  :", summ("SELECT COUNT(*) FROM tcgacati"), "\n")
cat("cohorts        :", summ("SELECT COUNT(*) FROM cohorts"), "\n")
cat("clinpheno cols :", paste(dbListFields(con, "clinpheno"), collapse = ", "), "\n")
cat("studies        :",
    paste(dbGetQuery(con, "SELECT study, COUNT(*) n FROM clinpheno GROUP BY study")$study,
          collapse = ", "), "\n")
cat("elapsed        :", round(difftime(Sys.time(), t0, units = "mins"), 1), "min\n")
cat("======================================================\n")

dbDisconnect(con)
say("DONE ->", OUT)
