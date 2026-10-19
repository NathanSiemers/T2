## test_multidataset.R — smoke test for multi-dataset support.
## Exercises registry discovery, both dataset bundles, and gitr() against both
## the real TCGA db and the synthetic DEMO db (incl. graceful filter no-ops).
suppressMessages({
  library(DBI)
  source("dataset_registry.R")
  source("database_connection_shiny.R")  # opens default `con` to tcga.db
  source("gitr.R")
  source("lib.R")                          # builds default bundle + globals
})

ok <- function(cond, msg) cat(if (cond) "  PASS " else "  FAIL ", msg, "\n")

cat("== Registry ==\n")
ds <- list_datasets()
cat("  datasets:", paste(ds, collapse = ", "), "\n")
ok(all(c("TCGA", "DEMO") %in% ds), "TCGA and DEMO both discovered")
ok(default_dataset() == "TCGA", "default dataset is TCGA")

cat("\n== Bundles ==\n")
bt <- load_dataset_bundle("TCGA")
bd <- load_dataset_bundle("DEMO")
cat("  TCGA: title =", bt$title, "| label =", bt$label, "\n")
cat("        roles: cohort_col =", bt$roles$cohort_col,
    "| subtype_col =", bt$roles$subtype_col,
    "| sampletype_col =", bt$roles$sampletype_col, "\n")
cat("        mygenesplus head:", paste(head(bt$mygenesplus, 5), collapse = ", "), "\n")
cat("        n probes =", length(bt$mygenes), "| n cohorts =", length(bt$mycohorts), "\n")
cat("  DEMO: title =", bd$title, "| label =", bd$label, "\n")
cat("        roles: cohort_col =", bd$roles$cohort_col,
    "| subtype_col =", bd$roles$subtype_col,
    "| sampletype_col =", ifelse(is.na(bd$roles$sampletype_col), "NA", bd$roles$sampletype_col), "\n")
cat("        mygenesplus head:", paste(head(bd$mygenesplus, 6), collapse = ", "), "\n")
cat("        cohorts:", paste(bd$mycohorts, collapse = ", "), "\n")
ok(is.na(bd$roles$sampletype_col), "DEMO has no sample-type role (as designed)")
ok(!"sample_type" %in% bd$mygenesplus, "DEMO choice list omits sample_type")
ok("growth_media" == bd$roles$subtype_col, "DEMO subtype role = growth_media")

cat("\n== gitr against TCGA ==\n")
dt <- gitr(c("CD8A", "cohort", "sample_type"),
           dbfile = bt$path, roles = bt$roles)
cat("  TCGA rows:", nrow(dt), "| has cohort:", "cohort" %in% names(dt),
    "| has CD8A:", "CD8A" %in% names(dt), "\n")
ok(nrow(dt) > 1000 && "cohort" %in% names(dt) && "CD8A" %in% names(dt),
   "TCGA gitr returns cohort + CD8A")
ok(is.numeric(dt$CD8A), "CD8A is numeric")

cat("\n== gitr against DEMO (with nonormal+noheme that should no-op) ==\n")
dd <- gitr(c("GENE01", "cohort", "subtype", "tissue_origin", "TP53_DRIVER"),
           dbfile = bd$path, roles = bd$roles,
           nonormal = TRUE, noheme = TRUE)
cat("  DEMO rows:", nrow(dd), "\n")
cat("  cols:", paste(intersect(c("cohort","subtype","tissue_origin","GENE01","TP53_DRIVER"),
                                names(dd)), collapse = ", "), "\n")
cat("  cohort vals:", paste(sort(unique(as.character(dd$cohort))), collapse = ", "), "\n")
cat("  subtype vals:", paste(sort(unique(as.character(dd$subtype))), collapse = ", "), "\n")
cat("  GENE01 range:", paste(round(range(dd$GENE01, na.rm = TRUE), 2), collapse = " - "), "\n")
cat("  TP53_DRIVER:", paste(sort(unique(as.character(dd$TP53_DRIVER))), collapse = ", "),
    "| class:", class(dd$TP53_DRIVER)[1], "\n")
ok(nrow(dd) == 60, "DEMO nonormal/noheme were no-ops (all 60 samples kept)")
ok("cohort" %in% names(dd) && all(dd$cohort %in% c("lung","breast","colon","skin","pancreas")),
   "DEMO virtual cohort maps to tissue_origin")
ok("subtype" %in% names(dd) && all(as.character(dd$subtype) %in% c("RPMI","DMEM")),
   "DEMO virtual subtype maps to growth_media")
ok(is.numeric(dd$GENE01) && median(dd$GENE01) > 5 && median(dd$GENE01) < 11,
   "DEMO GENE01 numeric on log2-TPM scale (~8, not TCGA scale)")
ok(is.factor(dd$TP53_DRIVER), "DEMO categorical driver is a factor")

cat("\n== gitr against CPTAC (skipped when datasets/cptac.db is absent) ==\n")
if (!"cptac" %in% ds) {
  cat("  (no cptac dataset discovered)\n")
} else {
  bc <- load_dataset_bundle("cptac")
  cat("  cptac: title =", bc$title, "| label =", bc$label, "\n")
  ok(bc$roles$cohort_col == "cancer_type" && bc$roles$sampletype_col == "sample_type",
     "cptac roles: cancer_type / sample_type")
  ## one probe of each data type: RNA is bare, the others carry their suffix
  cc <- RSQLite::dbConnect(RSQLite::SQLite(), bc$path, flags = RSQLite::SQLITE_RO)
  one <- function(suffix) DBI::dbGetQuery(cc, "SELECT probe FROM probes WHERE probe LIKE ? LIMIT 1",
                                          params = list(paste0("%", suffix)))$probe[1]
  pphos <- one(".phospho")
  DBI::dbDisconnect(cc)
  vars <- c("CD8A", "CD8A.prot", pphos, "TP53.mut", "TP53.fmut", "cohort", "sample_type", "OS", "OS.time")
  dc <- gitr(vars, dbfile = bc$path, roles = bc$roles)
  cat("  cptac rows:", nrow(dc), "| cols:", paste(intersect(vars, names(dc)), collapse = ", "), "\n")
  ok(nrow(dc) > 1000, "cptac gitr returns > 1000 samples")
  ok(is.numeric(dc$CD8A) && is.numeric(dc$CD8A.prot), "CD8A (rna) and CD8A.prot numeric")
  ok(!is.null(pphos) && is.numeric(dc[[pphos]]), paste("phosphosite numeric:", pphos))
  ok(mean(is.na(dc$CD8A.prot)) > 0 && mean(is.na(dc$CD8A.prot)) < 1, "protein has some NA (sparse=0 type), not all")
  ok(is.factor(dc$TP53.mut) && all(levels(dc$TP53.mut) %in% c("0", "1")), "TP53.mut is a 0/1 factor")
  ok(is.factor(dc$TP53.fmut), "TP53.fmut is a factor of mutation strings")
  ok(all(c("Primary Tumor", "Solid Tissue Normal") %in% dc$sample_type), "both sample types present")
  dn <- gitr(c("CD8A", "cohort"), dbfile = bc$path, roles = bc$roles, nonormal = TRUE)
  ok(nrow(dn) < nrow(dc), "nonormal drops the normal adjacent tissue")
  ok(is.numeric(dc$OS.time) && all(dc$OS %in% c(0, 1, NA)), "survival columns OS / OS.time")
}

cat("\n== Done ==\n")
