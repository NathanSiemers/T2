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

types_tbl <- data.frame(
  key  = 1:2,
  type = c("expr", "driver"),
  description = c("Synthetic gene expression (log2 TPM)",
                 "Synthetic driver-gene mutation call"),
  example     = c("GENE01", "TP53_DRIVER"),
  reference   = c("", ""),
  source_url  = c("", ""),
  source_file = c("build_demo_dataset.R", "build_demo_dataset.R"),
  stringsAsFactors = FALSE
)
datatypes_tbl <- data.frame(
  type = c("expr", "driver"),
  r_datatype = c("numeric", "factor"),
  stringsAsFactors = FALSE
)

## ---------------------------------------------------------------------------
## 3. Fact tables (long)
## ---------------------------------------------------------------------------
## numeric: every sample x every expr probe
expr_grid <- expand.grid(sample = samples, probe = expr_probes,
                         stringsAsFactors = FALSE)
expr_grid$value <- pmin(pmax(rnorm(nrow(expr_grid), mean = 8, sd = 2), 0), 16)
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
          "default_condition"),
  value = c("DEMO: Synthetic Cell-Line Panel (not real data)",
            "Synthetic Cell-Line Panel",
            "tissue_origin", "growth_media", "",
            "", "", "",
            "cohort", "GENE01", "subtype", "",
            ""),
  stringsAsFactors = FALSE
)

## ---------------------------------------------------------------------------
## 4. Write tables
## ---------------------------------------------------------------------------
dbWriteTable(con, "samples",      samples_tbl,   overwrite = TRUE)
dbWriteTable(con, "probes",       probes_tbl,    overwrite = TRUE)
dbWriteTable(con, "allprobes",    allprobes_tbl, overwrite = TRUE)
dbWriteTable(con, "types",        types_tbl,     overwrite = TRUE)
dbWriteTable(con, "datatypes",    datatypes_tbl, overwrite = TRUE)
dbWriteTable(con, "tested",       tested,        overwrite = TRUE)
dbWriteTable(con, "tcgai",        tcgai,         overwrite = TRUE)
dbWriteTable(con, "tcgacati",     tcgacati,      overwrite = TRUE)
dbWriteTable(con, "probe_types",  probe_types,   overwrite = TRUE)
dbWriteTable(con, "clinpheno",    clinpheno,     overwrite = TRUE)
dbWriteTable(con, "cohorts",      cohorts_tbl,   overwrite = TRUE)
dbWriteTable(con, "dataset_meta", dataset_meta,  overwrite = TRUE)

## ---------------------------------------------------------------------------
## 5. Indexes (mirror the TCGA build's performance indexes)
## ---------------------------------------------------------------------------
dbExecute(con, "CREATE INDEX probe_types_pk ON probe_types(probekey, type)")
dbExecute(con, "CREATE INDEX probe_types_tp ON probe_types(type, probekey)")
dbExecute(con, "CREATE INDEX tcgaiidx_pts ON tcgai(probekey, type, samplekey)")
dbExecute(con, "CREATE INDEX tcgacatiidx_pts ON tcgacati(probekey, type, samplekey)")
dbExecute(con, "CREATE INDEX tested_type ON tested(type)")
dbExecute(con, "CREATE INDEX tested_type_sample ON tested(type, sample)")
dbExecute(con, "CREATE INDEX clinphenoidx ON clinpheno(sample)")
dbExecute(con, "CREATE INDEX samplesidx ON samples(sample)")
dbExecute(con, "CREATE INDEX probesidx ON probes(probe)")

## ---------------------------------------------------------------------------
## 6. Views (identical DDL shape to 250-create_views.R)
## ---------------------------------------------------------------------------
dbExecute(con, "DROP VIEW IF EXISTS tcgas")
dbExecute(con, "
CREATE VIEW tcgas AS
SELECT sa.sample, pr.probe,
  CASE WHEN dat.probekey IS NOT NULL THEN dat.value ELSE 0 END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
LEFT JOIN tcgai dat ON dat.probekey = pr.key AND dat.samplekey = sa.key AND dat.type = pt.type")

dbExecute(con, "DROP VIEW IF EXISTS tcgacats")
dbExecute(con, "
CREATE VIEW tcgacats AS
SELECT sa.sample, pr.probe, dat.value, dat.type
FROM tcgacati dat
JOIN samples sa ON sa.key = dat.samplekey
JOIN probes pr ON pr.key = dat.probekey")

dbExecute(con, "DROP VIEW IF EXISTS tcga")
dbExecute(con, "
CREATE VIEW tcga AS
SELECT cp.*, pr.probe,
  CASE WHEN dat.probekey IS NOT NULL THEN dat.value ELSE 0 END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
JOIN clinpheno cp ON cp.sample = sa.sample
LEFT JOIN tcgai dat ON dat.probekey = pr.key AND dat.samplekey = sa.key AND dat.type = pt.type")

dbExecute(con, "DROP VIEW IF EXISTS tcgacat")
dbExecute(con, "
CREATE VIEW tcgacat AS
SELECT cp.*, pr.probe, dat.value, dat.type
FROM tcgacati dat
JOIN samples sa ON sa.key = dat.samplekey
JOIN probes pr ON pr.key = dat.probekey
JOIN clinpheno cp ON cp.sample = sa.sample")

## Serve in WAL mode so read-only app connections never block a writer.
dbExecute(con, "PRAGMA journal_mode=WAL")

cat("Built", dbpath, "\n")
cat("  samples:", nrow(samples_tbl),
    " probes:", nrow(probes_tbl),
    " allprobes:", nrow(allprobes_tbl),
    " tcgai rows:", nrow(tcgai),
    " tcgacati rows:", nrow(tcgacati), "\n")
cat("  clinpheno cols:", paste(colnames(clinpheno), collapse = ", "), "\n")
dbDisconnect(con)
