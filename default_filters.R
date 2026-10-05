## default_filters.R
## ============================================================================
## The `default_filters` table: named, ready-made subsets of a dataset's samples
## that a client offers as one-tap choices ("GTEx normal tissues", "Tumor samples
## only"), and which of them are switched on when the dataset is first opened.
##
## It lives IN each dataset's database (one source of truth, travels with the
## data). Every dataset builder calls write_default_filters(con, "<dataset>") at
## the end of its build:
##   TCGA/297-default_filters.R (run by TCGA/00-master.R), build_demo_dataset.R,
##   TCGATARGETGTEX/build_tcgatargetgtex.R.
##
## Table shape: one row per (preset, column, value).
##   preset         the name shown to the user
##   description    one line of explanation
##   column_name    a categorical clinpheno column, or the virtual `cohort` /
##                  `subtype` (the dataset's role columns, as gitr() names them)
##   op             'in' or 'not in'
##   value          ONE value of that column
##   on_by_default  1 = this preset is active when the dataset is first opened
##   sort_order     display order of the presets
## Reading a preset: rows sharing (column_name, op) are alternatives; a preset's
## different columns must all hold. E.g. "TCGA tumors" below =
##   study in (TCGA)  AND  sample_type not in (Solid Tissue Normal, Control Analyte)
##
## To change what a dataset offers: edit T2_DEFAULT_FILTERS and rebuild, or run
##   Rscript default_filters.R check <db> <dataset>     # validate only, read-only
##   Rscript default_filters.R write <db> <dataset>     # (re)write the table
## write refuses a definition that names a column or value the database does not
## have, so a typo cannot create a filter that silently selects nothing.
## ============================================================================

## preset(label, description, on, list(column = , op = , values = ), ...)
.preset = function(label, description, ..., on = FALSE) {
  list(label = label, description = description, on = on, rules = list(...))
}
.rule = function(column, op, values) list(column = column, op = op, values = values)

T2_DEFAULT_FILTERS = list(
  TCGA = list(
    .preset("Tumor samples only", "Leave out the matched normal tissue samples",
            .rule("sample_type", "not in", "Solid Tissue Normal")),
    .preset("Primary tumors only", "Primary tumors, including primary blood cancers",
            .rule("sample_type", "in", c("Primary Tumor", "Primary Blood Derived Cancer - Peripheral Blood"))),
    .preset("Metastatic samples only", "Metastases",
            .rule("sample_type", "in", c("Metastatic", "Additional Metastatic"))),
    .preset("Normal tissue only", "The matched normal tissue samples",
            .rule("sample_type", "in", "Solid Tissue Normal")),
    .preset("Exclude tumors of heme origin", "Leave out leukemia, lymphoma and thymoma cohorts",
            .rule("cohort", "not in", c("LAML", "THYM", "DLBC")))
  ),
  ## TCGA, TARGET and GTEx RNA-seq, processed by one pipeline (UCSC Toil):
  ## `study` separates the three sources.
  tcgatargetgtex = list(
    .preset("GTEx normal tissues", "Healthy donor tissue from GTEx (no cell lines)",
            .rule("study", "in", "GTEX"), .rule("sample_type", "in", "Normal Tissue")),
    .preset("TCGA tumors", "Adult tumors from TCGA, without the matched normals",
            .rule("study", "in", "TCGA"),
            .rule("sample_type", "not in", c("Solid Tissue Normal", "Control Analyte"))),
    .preset("TCGA matched normals", "Normal tissue adjacent to TCGA tumors",
            .rule("study", "in", "TCGA"), .rule("sample_type", "in", "Solid Tissue Normal")),
    .preset("TARGET pediatric cancers", "Childhood cancers from TARGET",
            .rule("study", "in", "TARGET")),
    .preset("All normal tissue", "GTEx tissue plus TCGA matched normals",
            .rule("sample_type", "in", c("Normal Tissue", "Solid Tissue Normal"))),
    .preset("Exclude cell lines", "Leave out the GTEx cell lines",
            .rule("sample_type", "not in", "Cell Line"))
  ),
  DEMO = list(
    .preset("Breast lines only", "Example preset for the synthetic demo data",
            .rule("cohort", "in", "breast"))
  )
)

## clinpheno as gitr() sees it for filtering: raw columns + virtual cohort / subtype
.df_clin = function(con) {
  clin = DBI::dbReadTable(con, "clinpheno", check.names = FALSE)
  meta = tryCatch({ m = DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta"); stats::setNames(m$value, m$key) },
                  error = function(e) c(cohort_col = "tumtype", subtype_col = "Subtype_Selected"))   # canonical TCGA
  cc = meta[["cohort_col"]]; sc = meta[["subtype_col"]]
  if (!is.null(sc) && !is.na(sc) && nzchar(sc) && sc %in% colnames(clin)) clin$subtype = clin[[sc]]
  if (!is.null(cc) && !is.na(cc) && nzchar(cc) && cc %in% colnames(clin)) clin$cohort = clin[[cc]]
  clin
}

## the table as a data frame, plus (per preset) how many samples it selects.
## Stops if a definition names something the database does not have.
default_filters_table = function(con, dataset, definitions = T2_DEFAULT_FILTERS[[dataset]]) {
  clin = .df_clin(con)
  rows = list(); counts = integer(0)
  for (i in seq_along(definitions)) {
    p = definitions[[i]]; keep = rep(TRUE, nrow(clin))
    for (r in p$rules) {
      if (!r$column %in% colnames(clin)) stop("default filter '", p$label, "': no column '", r$column, "' in ", dataset)
      if (!r$op %in% c("in", "not in")) stop("default filter '", p$label, "': op must be 'in' or 'not in'")
      bad = setdiff(r$values, unique(clin[[r$column]]))
      if (length(bad)) stop("default filter '", p$label, "': column '", r$column, "' has no value ", paste0("'", bad, "'", collapse = ", "))
      hit = clin[[r$column]] %in% r$values
      keep = keep & (if (r$op == "in") hit else !hit)
      rows[[length(rows) + 1]] = data.frame(preset = p$label, description = p$description, column_name = r$column,
                                            op = r$op, value = r$values, on_by_default = as.integer(isTRUE(p$on)),
                                            sort_order = i, stringsAsFactors = FALSE)
    }
    counts[p$label] = sum(keep)
  }
  out = if (length(rows)) do.call(rbind, rows) else
    data.frame(preset = character(0), description = character(0), column_name = character(0), op = character(0),
               value = character(0), on_by_default = integer(0), sort_order = integer(0))
  attr(out, "samples_selected") = counts
  attr(out, "n_samples") = nrow(clin)
  out
}

## (re)create the table in an open, writable build connection
write_default_filters = function(con, dataset) {
  tab = default_filters_table(con, dataset)
  DBI::dbWriteTable(con, "default_filters", tab[, c("preset", "description", "column_name", "op", "value", "on_by_default", "sort_order")],
                    overwrite = TRUE)
  n = attr(tab, "samples_selected")
  message(sprintf("default_filters (%s): %d preset(s), %d row(s)", dataset, length(n), nrow(tab)))
  for (l in names(n)) message(sprintf("  %-34s %6d of %d samples", l, n[[l]], attr(tab, "n_samples")))
  invisible(tab)
}

## command line: Rscript default_filters.R check|write <db> <dataset>
if (sys.nframe() == 0 && length(commandArgs(trailingOnly = TRUE)) == 3) local({
  a = commandArgs(trailingOnly = TRUE)
  ro = identical(a[1], "check")
  con = DBI::dbConnect(RSQLite::SQLite(), a[2], flags = if (ro) RSQLite::SQLITE_RO else RSQLite::SQLITE_RW)
  on.exit(DBI::dbDisconnect(con))
  if (ro) {
    tab = default_filters_table(con, a[3]); n = attr(tab, "samples_selected")
    cat(sprintf("%s: %d preset(s) valid against %s (nothing written)\n", a[3], length(n), a[2]))
    for (l in names(n)) cat(sprintf("  %-34s %6d of %d samples\n", l, n[[l]], attr(tab, "n_samples")))
  } else write_default_filters(con, a[3])
})
