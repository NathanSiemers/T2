## test_multidataset.R — multi-dataset support through the service (T2_API_URL).
## Exercises the datasets the service lists, every dataset's bundle (handles, time-to-event
## variables, type labels, About prose, default cohorts: what /meta declares, DATASET-CONTRACT.md),
## and gitr() against TCGA, the synthetic DEMO and CPTAC (incl. graceful filter no-ops).
suppressMessages({
  source("global.R")
  source("lib.R")                          # builds the default bundle + globals; stops without T2_API_URL
  source("input_validation.R")
})

source("t2_test_helpers.R")   # ok() counts failures, finish() exits non-zero, quiet()

cat("== Datasets (from /v1/datasets) ==\n")
ds <- t2_datasets()
cat("  datasets:", paste(ds, collapse = ", "), "\n")
ok(all(c("TCGA", "DEMO") %in% ds), "TCGA and DEMO both listed")
ok(t2_default_dataset() == "TCGA", "default dataset is TCGA")
srcs <- list_sources()
hid <- vapply(t2_api_datasets(), function(d) t2_dataset_hidden(d), NA)
ok(all(ds[!hid] %in% sub("\\|.*", "", srcs)) && !any(ds[hid] %in% sub("\\|.*", "", srcs)),
   "the Data set menu is built from /v1/datasets and covers every dataset that is not hidden")

cat("\n== Bundles: what the service declares ==\n")
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

cat("\n== Handles, time-to-event variables, type labels, About, default cohorts (the contract) ==\n")
roles_of <- function(b) stats::setNames(b$handles$role, b$handles$name)
want_handles <- list(TCGA = c(subtype = "subcohort", cohort = "cohort", sample_type = "sample_type"),
                     cptac = c(cohort = "cohort", sample_type = "sample_type"),
                     tcgatargetgtex = c(subtype = "subcohort", cohort = "cohort", sample_type = "sample_type"),
                     DEMO = c(subtype = "subcohort", cohort = "cohort"))
want_tte <- list(TCGA = c("OS", "PFI", "DSS", "DFI"), cptac = c("OS", "PFI"), tcgatargetgtex = character(0))
for (d in intersect(ds, names(want_handles))) {
  b <- load_dataset_bundle(d)
  ok(identical(roles_of(b), want_handles[[d]]), sprintf("%s handles: %s", d, paste(sprintf("%s (%s)", b$handles$name, b$handles$role), collapse = ", ")))
  ok(all(b$handles$name %in% b$mygenesplus) && identical(head(b$mygenesplus, nrow(b$handles)), b$handles$name),
     sprintf("%s: the handles lead the variable menu", d))
  ok(!any(b$handles$name %in% b$mygenes), sprintf("%s: no handle among the probes", d))
  m <- t2_api_meta(d)
  served <- as.character(unlist(m$survival_endpoints))
  ok(identical(tte_names(b), served), sprintf("%s time-to-event variables = /meta survival_endpoints: %s", d,
                                                 if (length(served)) paste(served, collapse = ", ") else "(none)"))
  if (!is.null(want_tte[[d]])) ok(identical(tte_names(b), want_tte[[d]]), sprintf("%s declares %d time-to-event variable(s)", d, length(want_tte[[d]])))
  for (t in b$tte) ok(all(c(t$event_col, t$time_col) %in% colnames(b$clin)) && identical(t$time_unit, "days"),
                      sprintf("%s tte %s: event / time columns exist, unit days", d, t$name))
  ok(setequal(names(b$type_labels), b$types$type), sprintf("%s type_labels cover every data type (%d)", d, length(b$type_labels)))
  ok(is.character(b$about$description) && is.character(b$about$citation) && is.character(b$about$attribution) && is.character(b$about$url),
     sprintf("%s About has description / citation / attribution / url", d))
  ok(identical(b$default_cohorts, as.character(unlist(m$default_cohorts))) && all(b$default_cohorts %in% b$mycohorts),
     sprintf("%s default cohorts (%d) are cohorts of the dataset", d, length(b$default_cohorts)))
}
ok("OS" %in% tte_names(bd), "DEMO declares its synthetic OS")
ok(bt$type_labels[["mut"]] == "mutation" && bt$type_labels[["cnv"]] == "CNA", "TCGA type labels: mut -> mutation, cnv -> CNA")
ok(nzchar(bt$about$citation) && nzchar(bt$about$attribution), "TCGA About: citation and attribution")
ok(identical(bt$default_cohorts, c("COAD", "ESCA", "HNSC", "KIRC", "LUAD", "LUSC", "PAAD", "SKCM", "STAD")), "TCGA opens on its nine cohorts")
ok(bd$type_labels[["driver"]] == "mutation" && bd$type_labels[["expr"]] == "", "DEMO type labels: driver -> mutation, expr -> (none)")
if ("cptac" %in% ds) {
  bc0 <- load_dataset_bundle("cptac")
  cat("  cptac type labels:", paste(sprintf("%s=\"%s\"", names(bc0$type_labels), bc0$type_labels), collapse = " "), "\n")
  if (!nzchar(bc0$about$attribution)) cat("  NOTE: the cptac file served here has no About / attribution yet (the data layer fills it); not counted\n")
  else ok(grepl("National Cancer Institute|NCI|CPTAC", bc0$about$attribution), "cptac About carries the data provider's attribution")
}
## the title words come from the labels
bw <- list(menu = bt$menu, type_labels = bt$type_labels)
ok(identical(t2_title_name(c("TP53.mut", "CD8A", "TP53.cnv"), bw), c("TP53 mutation", "CD8A", "TP53 CNA")), "title words from type_labels (TP53.mut -> 'TP53 mutation', bare RNA unchanged)")

## a part of a collection names itself in the plot title (not the whole collection)
btg <- load_source_bundle("tcgatargetgtex|GTEx")
whole <- load_source_bundle("tcgatargetgtex")
ok(identical(t2_plot_ctx(btg)$label, btg$source$label) && !identical(t2_plot_ctx(btg)$label, whole$label) &&
   identical(t2_plot_ctx(whole)$label, whole$label),
   sprintf("source part: the title's dataset word is the part's label ('%s', not '%s')", t2_plot_ctx(btg)$label, whole$label))
pg <- t2_figure_object(quiet(fun_plot1(list(x = "TP53", y = "CD8A", cohort = "all", allComplete = TRUE), reactive = FALSE, ctx = t2_plot_ctx(btg))))
ok(grepl(paste0("across ", btg$source$label), pg$labels$title, fixed = TRUE) && !grepl(whole$label, pg$labels$title, fixed = TRUE),
   "the plot title reads 'across <part label>'")

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

cat("\n== gitr against CPTAC (skipped when the service does not serve cptac) ==\n")
if (!"cptac" %in% ds) {
  cat("  (no cptac dataset discovered)\n")
} else {
  bc <- load_dataset_bundle("cptac")
  cat("  cptac: title =", bc$title, "| label =", bc$label, "\n")
  ok(bc$roles$cohort_col == "cancer_type" && bc$roles$sampletype_col == "sample_type",
     "cptac roles: cancer_type / sample_type")
  ## one probe of each data type: RNA is bare, the others carry their suffix. The phosphosite
  ## comes from the bundle's variable menu (works over the files and over the service alike).
  pphos <- grep("\\.phospho$", bc$mygenesplus, value = TRUE)[1]
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

finish("test_multidataset")
