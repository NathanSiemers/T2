## dataset_meta.R -- read or set keys of a dataset's dataset_meta table, and the types.label words.
##   Rscript dataset_meta.R show      <db>
##   Rscript dataset_meta.R set       <db> key=value [key=value ...]   (lists: a|b|c; creates the table when missing)
##   Rscript dataset_meta.R set-json  <db> key @file.json              (validates the JSON, stores it compact)
##   Rscript dataset_meta.R type-label <db> type=label [type=label ...] (adds types.label when absent;
##                                                                      refuses an unknown type; rna= sets "")
## All writes go through t2_build_lib.R (t2_write_meta / t2_write_types), the one writer the builders use too;
## an unknown dataset_meta key is refused. `show` prints a JSON value (tte_variables) pretty. For the keys and their meaning see
## T2Mobile/docs/DATASET-CONTRACT.md (the contract), dataset_registry.R (roles, defaults) and
## t2_presets.R (source_col, sources, source_labels, source_descriptions).
## Every mode refuses a path under /scratch/shinyusb (the served files). Never run against a
## SERVED database file: stage a copy, change it, test it, and deploy by a new directory / atomic mv.
args = commandArgs(trailingOnly = TRUE)
usage = "usage: Rscript dataset_meta.R show|set|set-json|type-label <db> [args ...]"
if (length(args) < 2) stop(usage)
mode = args[1]; db = args[2]
if (!mode %in% c("show", "set", "set-json", "type-label")) stop(usage)
.p = normalizePath(db, mustWork = FALSE)
if (grepl("^/scratch/shinyusb(/|$)", .p) || grepl("^/scratch/shinyusb(/|$)", db))
  stop("refusing a served path: ", db)
if (!file.exists(db)) stop("no such file: ", db)
ro = identical(mode, "show")
con = DBI::dbConnect(RSQLite::SQLite(), db, flags = if (ro) RSQLite::SQLITE_RO else RSQLite::SQLITE_RW)
on.exit(DBI::dbDisconnect(con))
invisible(DBI::dbExecute(con, "PRAGMA busy_timeout = 60000"))
has_meta = function() "dataset_meta" %in% DBI::dbListTables(con)
if (!ro) {
  .here = dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
  source(file.path(.here, "t2_views.R")); source(file.path(.here, "t2_build_lib.R"))   # the one writer of dataset_meta / types
}

if (mode == "set") {
  if (length(args) < 3) stop("set: need key=value ...")
  kv = args[-(1:2)]
  if (any(!grepl("=", kv, fixed = TRUE))) stop("not key=value: ", paste(kv[!grepl("=", kv, fixed = TRUE)], collapse = " "))
  m = setNames(as.list(sub("^[^=]*=", "", kv)), sub("=.*", "", kv, perl = TRUE))   # values verbatim (lists: a|b|c)
  t2_write_meta(con, meta = m)
} else if (mode == "set-json") {
  if (length(args) != 4 || !startsWith(args[4], "@")) stop("set-json: need  key @file.json")
  if (!identical(args[3], "tte_variables")) stop("set-json: only tte_variables holds JSON, not ", args[3])
  f = substring(args[4], 2)
  if (!file.exists(f)) stop("no such json file: ", f)
  t2_write_meta(con, tte = paste(readLines(f, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
} else if (mode == "type-label") {
  if (length(args) < 3) stop("type-label: need type=label ...")
  kv = args[-(1:2)]
  if (any(!grepl("=", kv, fixed = TRUE))) stop("not type=label: ", paste(kv[!grepl("=", kv, fixed = TRUE)], collapse = " "))
  t2_write_types(con, data.frame(type = sub("=.*", "", kv), label = sub("^[^=]*=", "", kv), stringsAsFactors = FALSE), allow_new = FALSE)
  m = DBI::dbGetQuery(con, "SELECT type, label FROM types ORDER BY key")
  for (i in seq_len(nrow(m))) cat(sprintf("%-18s \"%s\"\n", m$type[i], m$label[i]))
  quit(save = "no", status = 0)
}
if (!has_meta()) stop("no dataset_meta table in ", db)
m = DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta")
for (i in seq_len(nrow(m))) {
  v = m$value[i]
  if (!is.na(v) && grepl("^\\s*[\\[{]", v) && isTRUE(jsonlite::validate(v)))
    cat(sprintf("%-22s\n%s\n", m$key[i], paste0("  ", strsplit(as.character(jsonlite::prettify(v, indent = 2)), "\n")[[1]], collapse = "\n")))
  else cat(sprintf("%-22s %s\n", m$key[i], v))
}
