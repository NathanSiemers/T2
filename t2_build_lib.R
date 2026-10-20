## t2_build_lib.R -- what every T2 dataset builder (and dataset_meta.R, TCGA/write_tcga_meta.R)
## shares for writing a dataset's self-description. Source it next to t2_views.R.
## The contract: T2Mobile/docs/DATASET-CONTRACT.md. Nothing here is dataset-specific.
##
##   t2_write_meta(con, meta = list(title=, label=, ..., default_cohorts = c("A","B")),
##                 tte = list(t2_tte("OS", "Overall Survival", "OS", "OS.time")))
##   t2_write_types(con, spec)       spec: data.frame(type, description, example, reference, source_url,
##                                   source_file, label, r_datatype, sparse, default_value); only `type`
##                                   is required, a column that is absent or NA is left as it is
##   t2_finalize_dataset(con, name, filters = name)
##                                   drop_t2_dataless_probes + finalize_t2_core + write_default_filters
##                                   + check_dataset_contract; stops when the check FAILS

## every key of dataset_meta the contract knows (lists are "|"-separated)
T2_META_KEYS <- c("title", "label", "cohort_col", "subtype_col", "sampletype_col", "sampletype_levels",
                  "normal_label", "heme_values", "default_x", "default_y", "default_color", "default_size",
                  "default_condition", "default_cohorts", "source_col", "sources", "source_labels",
                  "source_descriptions", "tte_variables", "about", "citation", "attribution", "about_url", "order")   # order: optional integer, ascending in the dataset list
T2_TTE_FIELDS <- c("name", "label", "event_col", "time_col", "time_unit", "description")

if (!exists("set_t2_sparse")) stop("source t2_views.R before t2_build_lib.R")

t2_ensure_columns <- function(con, table, cols) {   # cols: named character vector name -> SQL type/default
  have <- DBI::dbListFields(con, table)
  for (nm in setdiff(names(cols), have))
    DBI::dbExecute(con, sprintf("ALTER TABLE %s ADD COLUMN %s %s", table, nm, cols[[nm]]))
  invisible(setdiff(names(cols), have))
}

t2_tte <- function(name, label, event_col, time_col, time_unit = "days", description = "")
  list(name = name, label = label, event_col = event_col, time_col = time_col,
       time_unit = time_unit, description = description)

## tte: a list of t2_tte() (list() = none, written as []), or an already-serialized JSON string
t2_tte_json <- function(tte) {
  if (is.character(tte) && length(tte) == 1) {
    if (!isTRUE(jsonlite::validate(tte))) stop("tte_variables is not valid JSON")
    x <- jsonlite::fromJSON(tte, simplifyVector = FALSE)
    if (length(x) && !is.null(names(x))) stop("tte_variables must be a JSON array of objects")
    tte <- x
  }
  tte <- lapply(tte, function(v) {
    bad <- setdiff(names(v), T2_TTE_FIELDS); if (length(bad)) stop("unknown tte field(s): ", paste(bad, collapse = ", "))
    lapply(setNames(T2_TTE_FIELDS, T2_TTE_FIELDS), function(k) { x <- v[[k]]; if (is.null(x)) "" else as.character(x) })
  })
  if (!length(tte)) return("[]")
  as.character(jsonlite::toJSON(unname(tte), auto_unbox = TRUE))
}

t2_write_meta <- function(con, meta = list(), tte = NULL) {
  if (!is.null(meta$tte_variables)) { if (is.null(tte)) tte <- meta$tte_variables; meta$tte_variables <- NULL }
  bad <- setdiff(names(meta), T2_META_KEYS)
  if (length(bad)) stop("unknown dataset_meta key(s): ", paste(bad, collapse = ", "), " (known: ", paste(T2_META_KEYS, collapse = ", "), ")")
  if (!is.null(tte)) meta$tte_variables <- t2_tte_json(tte)
  vals <- vapply(meta, function(v) if (is.null(v) || (length(v) == 1 && is.na(v))) NA_character_ else paste(as.character(v), collapse = "|"), "")
  vals <- vals[!is.na(vals)]
  DBI::dbBegin(con)
  tryCatch({
    if (!"dataset_meta" %in% DBI::dbListTables(con))
      DBI::dbExecute(con, "CREATE TABLE dataset_meta(key TEXT PRIMARY KEY, value TEXT)")
    for (k in names(vals)) {
      DBI::dbExecute(con, "DELETE FROM dataset_meta WHERE key = ?", params = list(k))
      DBI::dbExecute(con, "INSERT INTO dataset_meta(key, value) VALUES (?, ?)", params = list(k, unname(vals[[k]])))
    }
    DBI::dbCommit(con)
  }, error = function(e) { try(DBI::dbRollback(con), silent = TRUE); stop(e) })
  invisible(names(vals))
}

t2_write_types <- function(con, spec, allow_new = TRUE) {
  spec <- as.data.frame(spec, stringsAsFactors = FALSE)
  stopifnot("type" %in% names(spec), !anyDuplicated(spec$type))
  has <- function(k) k %in% names(spec)
  tcols <- c("description", "example", "reference", "source_url", "source_file", "label")
  DBI::dbBegin(con)
  tryCatch({
    if (!"types" %in% DBI::dbListTables(con)) {
      if (!allow_new) stop("no types table")
      t <- data.frame(key = seq_len(nrow(spec)), type = spec$type, stringsAsFactors = FALSE)
      for (k in tcols) t[[k]] <- if (has(k)) as.character(spec[[k]]) else rep("", nrow(spec))
      DBI::dbWriteTable(con, "types", t, overwrite = TRUE)
    } else {
      known <- DBI::dbGetQuery(con, "SELECT type FROM types")$type
      new <- setdiff(spec$type, known)
      if (length(new) && !allow_new) stop("unknown type(s): ", paste(new, collapse = ", "), " (types: ", paste(known, collapse = ", "), ")")
      t2_ensure_columns(con, "types", c(label = "TEXT DEFAULT ''"))
      if (length(new)) {                      # new rows: all the text columns; existing rows: label only
        k0 <- DBI::dbGetQuery(con, "SELECT COALESCE(MAX(key), 0) k FROM types")$k
        for (i in seq_along(new)) {
          r <- spec[spec$type == new[i], , drop = FALSE]
          DBI::dbExecute(con, "INSERT INTO types(key, type) VALUES (?, ?)", params = list(k0 + i, new[i]))
          for (k in setdiff(tcols, "label")) if (has(k) && !is.na(r[[k]]))
            DBI::dbExecute(con, sprintf("UPDATE types SET %s = ? WHERE type = ?", k), params = list(as.character(r[[k]]), new[i]))
        }
      }
      if (has("label")) for (i in seq_len(nrow(spec))) if (!is.na(spec$label[i]))
        DBI::dbExecute(con, "UPDATE types SET label = ? WHERE type = ?", params = list(as.character(spec$label[i]), spec$type[i]))
    }
    if (has("r_datatype")) {
      s <- spec[!is.na(spec$r_datatype), , drop = FALSE]
      if (!"datatypes" %in% DBI::dbListTables(con))
        DBI::dbWriteTable(con, "datatypes", data.frame(type = s$type, r_datatype = s$r_datatype, stringsAsFactors = FALSE), overwrite = TRUE)
      else for (i in seq_len(nrow(s))) {
        DBI::dbExecute(con, "DELETE FROM datatypes WHERE type = ?", params = list(s$type[i]))
        DBI::dbExecute(con, "INSERT INTO datatypes(type, r_datatype) VALUES (?, ?)", params = list(s$type[i], s$r_datatype[i]))
      }
    }
    DBI::dbCommit(con)
  }, error = function(e) { try(DBI::dbRollback(con), silent = TRUE); stop(e) })
  if (has("sparse")) for (i in which(!is.na(spec$sparse))) {      # same semantics as set_t2_sparse()
    dv <- if (has("default_value") && !is.na(spec$default_value[i])) spec$default_value[i] else 0
    set_t2_sparse(con, spec$type[i], isTRUE(as.logical(spec$sparse[i])), dv)
  }
  invisible(spec$type)
}

t2_finalize_dataset <- function(con, name, filters = name) {
  n <- drop_t2_dataless_probes(con)
  message("probes with no data at all removed from probes/allprobes: ", n)
  if (!is.null(filters) && !isFALSE(filters)) write_default_filters(con, filters)
  finalize_t2_core(con)
  if (!exists("check_dataset_contract")) stop("source dataset_contract_check.R before t2_finalize_dataset()")
  chk <- check_dataset_contract(con, name)
  if (!chk$ok) stop("dataset contract check FAILED for '", name, "'")
  invisible(list(dropped = n, contract = chk))
}
