## build_demo_dataset.R
## ============================================================================
## Build a SMALL, SYNTHETIC second dataset to prove the multi-dataset
## architecture (see MULTIDATASET.md). It is NOT real data.
##
## The point is to be deliberately UNLIKE TCGA so the schema/app flexibility is
## actually exercised:
##   * clinical columns are completely different (cell_line, tissue_origin,
##     growth_media, passage_number, doubling_time_hr, mutation_status_TP53 —
##     none of TCGA's tumtype/gender/race/stage/sample_type)
##   * numeric values live on a different scale (log2 TPM ~ N(8,2) in [0,16])
##   * there is NO sample-type / normal concept, so the nonormal/noheme filters
##     must become no-ops automatically
##
## It produces datasets/DEMO.db with the exact T2 schema shape (samples,
## probes, allprobes, types, datatypes, tested, tcgai, tcgacati, probe_types,
## clinpheno, cohorts) + the tcgas/tcgacats/tcga/tcgacat views + a
## self-describing dataset_meta(key,value) table.
## ============================================================================

library(DBI)
library(RSQLite)
source("t2_views.R"); source("t2_build_lib.R"); source("default_filters.R"); source("dataset_contract_check.R")
set.seed(42)

dir.create("datasets", showWarnings = FALSE)
dbpath <- file.path("datasets", "DEMO.db")
if (file.exists(dbpath)) file.remove(dbpath)
con <- dbConnect(SQLite(), dbpath)

## ---------------------------------------------------------------------------
## 1. Content definition
## ---------------------------------------------------------------------------
n_samples <- 60
samples   <- sprintf("CL%03d", seq_len(n_samples))

tissues <- sample(c("lung", "breast", "colon", "skin", "pancreas"),
                  n_samples, replace = TRUE)
media   <- sample(c("RPMI", "DMEM"), n_samples, replace = TRUE)

clinpheno <- data.frame(
  sample               = samples,
  cell_line            = paste0("CellLine-", samples),
  tissue_origin        = tissues,
  growth_media         = media,
  passage_number       = sample(5:40, n_samples, replace = TRUE),
  doubling_time_hr     = round(runif(n_samples, 18, 72), 1),
  mutation_status_TP53 = sample(c("WT", "MUT"), n_samples, replace = TRUE),
  stringsAsFactors     = FALSE
)

## a synthetic survival pair, so that every suite exercises time-to-event analysis: OS is 1 (event) or
## 0 (censored), OS.time days > 0. Drawn from a separate seed and the generator state restored, so the
## rest of the DEMO data is exactly what it was before this pair existed.
local({
  rs <- get0(".Random.seed", envir = globalenv(), inherits = FALSE)
  set.seed(1234)
  clinpheno$OS      <<- rbinom(n_samples, 1, 0.55)
  clinpheno$OS.time <<- pmax(1, round(rexp(n_samples, 1 / 900) + 30))
  if (!is.null(rs)) assign(".Random.seed", rs, envir = globalenv())
})

expr_probes   <- sprintf("GENE%02d", 1:40)            # numeric, type 'expr'
driver_probes <- c("TP53_DRIVER", "KRAS_DRIVER", "EGFR_DRIVER")  # categorical, type 'driver'
measured_probes <- c(expr_probes, driver_probes)
## clinical columns are also selectable "probes" (mirrors TCGA's allprobes)
clin_vars <- setdiff(colnames(clinpheno), "sample")
all_probes <- c(measured_probes, clin_vars)

## ---------------------------------------------------------------------------
## 2. Dimension tables
## ---------------------------------------------------------------------------
samples_tbl <- data.frame(key = seq_along(samples), sample = samples,
                          stringsAsFactors = FALSE)
probes_tbl  <- data.frame(key = seq_along(measured_probes), probe = measured_probes,
                          stringsAsFactors = FALSE)
allprobes_tbl <- data.frame(key = seq_along(all_probes), probe = all_probes,
                            stringsAsFactors = FALSE)
sample_key <- setNames(samples_tbl$key, samples_tbl$sample)
probe_key  <- setNames(probes_tbl$key,  probes_tbl$probe)

## types, datatypes and the sparse model (every sample x probe value is stored) in one table; t2_build_lib.R writes all three
type_spec <- data.frame(
  type = c("expr", "driver"),
  description = c("Synthetic gene expression (log2 TPM)",
                 "Synthetic driver-gene mutation call"),
  example     = c("GENE01", "TP53_DRIVER"),
  reference   = c("", ""),
  source_url  = c("", ""),
  source_file = c("build_demo_dataset.R", "build_demo_dataset.R"),
  label       = c("", "mutation"),
  r_datatype  = c("numeric", "factor"),
  sparse      = c(FALSE, NA),          # only the numeric type has a sparse model; the categorical one has no row
  default_value = NA_real_,
  stringsAsFactors = FALSE
)

## ---------------------------------------------------------------------------
## 3. Fact tables (long)
## ---------------------------------------------------------------------------
## numeric: every sample x every expr probe
expr_grid <- expand.grid(sample = samples, probe = expr_probes,
                         stringsAsFactors = FALSE)
expr_grid$value <- round(pmin(pmax(rnorm(nrow(expr_grid), mean = 8, sd = 2), 0), 16), 6)   # 6 decimals: no float noise in the file
tcgai <- data.frame(
  samplekey = sample_key[expr_grid$sample],
  probekey  = probe_key[expr_grid$probe],
  value     = expr_grid$value,
  type      = "expr",
  stringsAsFactors = FALSE
)

## categorical: every sample x every driver probe
drv_grid <- expand.grid(sample = samples, probe = driver_probes,
                        stringsAsFactors = FALSE)
drv_grid$value <- sample(c("WT", "MUT"), nrow(drv_grid), replace = TRUE,
                         prob = c(0.7, 0.3))
tcgacati <- data.frame(
  samplekey = sample_key[drv_grid$sample],
  probekey  = probe_key[drv_grid$probe],
  value     = drv_grid$value,
  type      = "driver",
  stringsAsFactors = FALSE
)

## tested: which (sample, type) pairs were assayed (value column unused by view)
tested <- rbind(
  data.frame(sample = samples, value = 1L, type = "expr",   stringsAsFactors = FALSE),
  data.frame(sample = samples, value = 1L, type = "driver", stringsAsFactors = FALSE)
)

## probe_types lookup (probekey, type) — distinct, built from the NUMERIC
## fact table only, exactly as 250-create_views.R does
## (SELECT DISTINCT probekey, type FROM tcgai). Categorical (driver) probes
## live only in tcgacati and must NOT appear here, otherwise the dense numeric
## tcgas view would surface them with the CASE-ELSE-0 default and gitr would
## never fall through to the categorical tcgacats view.
probe_types <- unique(data.frame(
  probekey = probe_key[expr_probes], type = "expr", stringsAsFactors = FALSE))

## cohorts table from tissue origins
co <- sort(unique(tissues))
cohorts_tbl <- data.frame(
  cohort = co, lcohort = co,
  cohortstring = tools::toTitleCase(co),
  stringsAsFactors = FALSE
)

## self-describing metadata
dataset_meta <- data.frame(
  key = c("title", "label",
          "cohort_col", "subtype_col", "sampletype_col",
          "normal_label", "heme_values", "sampletype_levels",
          "default_x", "default_y", "default_color", "default_size",
          "default_condition",
          "tte_variables", "references", "about", "citation", "attribution", "about_url"),
  value = c("DEMO: Synthetic Cell-Line Panel (not real data)",
            "Synthetic Cell-Line Panel",
            "tissue_origin", "growth_media", "",
            "", "", "",
            "cohort", "GENE01", "subtype", "",
            "",
            as.character(jsonlite::toJSON(list(
              list(name = "OS", label = "Overall Survival", event_col = "OS", time_col = "OS.time", time_unit = "days",
                   description = "Synthetic overall survival (random event and follow-up days; not real data).")),
              auto_unbox = TRUE)),
            "[]",   # references: synthetic data, no publication
            paste("DEMO is a small SYNTHETIC panel of 60 cell lines with 40 random expression probes and 3 random driver-mutation calls.",
                  "It is not real data: it exists to test the T2 apps and services, and to show that a dataset with a clinical vocabulary",
                  "unlike TCGA works. Its OS / OS.time pair is random, to exercise the Kaplan-Meier analysis."),
            "Synthetic data generated by build_demo_dataset.R (T2); no publication.",
            "Synthetic data: not derived from any patient or cell-line measurement.",
            ""),
  stringsAsFactors = FALSE
)

## ---------------------------------------------------------------------------
## 4. Write tables
## ---------------------------------------------------------------------------
dbWriteTable(con, "samples",      samples_tbl,   overwrite = TRUE)
dbWriteTable(con, "probes",       probes_tbl,    overwrite = TRUE)
dbWriteTable(con, "allprobes",    allprobes_tbl, overwrite = TRUE)
dbWriteTable(con, "tested",       tested,        overwrite = TRUE)
dbWriteTable(con, "tcgai",        tcgai,         overwrite = TRUE)
dbWriteTable(con, "tcgacati",     tcgacati,      overwrite = TRUE)
dbWriteTable(con, "probe_types",  probe_types,   overwrite = TRUE)
dbWriteTable(con, "clinpheno",    clinpheno,     overwrite = TRUE)
dbWriteTable(con, "cohorts",      cohorts_tbl,   overwrite = TRUE)
t2_write_types(con, type_spec)
t2_write_meta(con, meta = setNames(as.list(dataset_meta$value), dataset_meta$key))   # lists are already "|"-joined above

## ---------------------------------------------------------------------------
## 5. Everything else, the shared way (t2_build_lib.R): the data-less probe cleanup, probe_types, indexes and
##    views (t2_views.R), the ready-made sample subsets for clients (default_filters.R), rollback-journal mode
##    (a single file, readable by the read-only app containers) and the dataset contract
##    (T2Mobile/docs/DATASET-CONTRACT.md s.4) -- a file that fails it is not released
## ---------------------------------------------------------------------------
invisible(t2_finalize_dataset(con, "DEMO"))

cat("Built", dbpath, "\n")
cat("  samples:", nrow(samples_tbl),
    " probes:", nrow(probes_tbl),
    " allprobes:", nrow(allprobes_tbl),
    " tcgai rows:", nrow(tcgai),
    " tcgacati rows:", nrow(tcgacati), "\n")
cat("  clinpheno cols:", paste(colnames(clinpheno), collapse = ", "), "\n")
dbDisconnect(con)
