## dataset_meta.R -- read or set keys of a dataset's dataset_meta table, and the types.label words.
##   Rscript dataset_meta.R show      <db>
##   Rscript dataset_meta.R set       <db> key=value [key=value ...]   (lists: a|b|c; creates the table when missing)
##   Rscript dataset_meta.R set-json  <db> key @file.json              (tte_variables | references; validates the JSON, stores it compact)
##   Rscript dataset_meta.R type-fill  <db> type=na|zero|floor [type=...] (adds types.fill_options when absent; the
##                                                                      not-detected fills the type offers, na first)
##   Rscript dataset_meta.R type-label <db> type=label [type=label ...] (adds types.label when absent;
##                                                                      refuses an unknown type; rna= sets "")
## All writes go through t2_build_lib.R (t2_write_meta / t2_write_types), the one writer the builders use too;
## an unknown dataset_meta key is refused. `show` prints a JSON value (tte_variables, references) pretty. For the keys and their meaning see
## T2Mobile/docs/DATASET-CONTRACT.md (the contract), dataset_registry.R (roles, defaults) and
## t2_presets.R (source_col, sources, source_labels, source_descriptions).
## Every write is checked: the contract check (deep = FALSE) runs before and after the write inside one SAVEPOINT
## on the one connection. The write is rolled back (FAIL rows printed, exit 1, file unchanged) when the FAIL messages
## after it are not a subset of those before: a file that already fails stays repairable one key at a time, a write
## that adds or changes a failure is refused. Pre-existing FAILs are printed as a warning.
## A file with no `clinpheno` table is refused ("not a T2 dataset"). type-fill refuses a fill other than na
## for a sparse type (a type with no sparse row counts as sparse).
## Every mode refuses a served path (t2_refuse_served: /scratch/shinyusb, /scratch/Docker, $T2_SERVED_ROOTS).
## Never run against a SERVED database file: stage a copy, change it, test it, and deploy by a new directory / atomic mv.
args = commandArgs(trailingOnly = TRUE)
usage = "usage: Rscript dataset_meta.R show|set|set-json|type-label|type-fill <db> [args ...]"
if (length(args) < 2) stop(usage)
mode = args[1]; db = args[2]
if (!mode %in% c("show", "set", "set-json", "type-label", "type-fill")) stop(usage)
.here = dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
source(file.path(.here, "t2_views.R")); source(file.path(.here, "t2_build_lib.R"))   # the one writer of dataset_meta / types, and the served-path guard
t2_refuse_served(db)
if (!file.exists(db)) stop("no such file: ", db)
ro = identical(mode, "show")
con = DBI::dbConnect(RSQLite::SQLite(), db, flags = if (ro) RSQLite::SQLITE_RO else RSQLite::SQLITE_RW)
on.exit(DBI::dbDisconnect(con))
invisible(DBI::dbExecute(con, "PRAGMA busy_timeout = 60000"))
if (!"clinpheno" %in% DBI::dbListTables(con)) stop("not a T2 dataset (no clinpheno table): ", db)
has_meta = function() "dataset_meta" %in% DBI::dbListTables(con)
if (!ro) source(file.path(.here, "dataset_contract_check.R"))

## write() and the contract check in one savepoint: a FAIL (or an error) undoes the write, the file stays as it was
guarded = function(write) {
  invisible(DBI::dbExecute(con, "SAVEPOINT dataset_meta_cli"))
  undo = function() { try(DBI::dbExecute(con, "ROLLBACK TO dataset_meta_cli"), silent = TRUE); try(DBI::dbExecute(con, "RELEASE dataset_meta_cli"), silent = TRUE) }
  nm = sub("\\.db$", "", basename(db))
  fails = function(r) { f = r$results[r$results$status == "FAIL", , drop = FALSE]; setNames(f$detail, paste(f$group, f$test, sep = "|")) }
  key = function(f) paste(names(f), f)
  before = fails(check_dataset_contract(con, nm, verbose = FALSE, deep = FALSE))
  if (length(before)) for (i in seq_along(before)) cat(sprintf("WARNING: already failing before this write: [%s] %s\n", names(before)[i], before[i]))
  chk = tryCatch({ write(); check_dataset_contract(con, nm, verbose = FALSE, deep = FALSE) },
                 error = function(e) { undo(); stop(e) })
  if (!all(key(fails(chk)) %in% key(before))) {
    undo()
    f = chk$results[chk$results$status == "FAIL", , drop = FALSE]
    cat("REFUSED: the write would add or change a failure of the contract check; nothing was changed.\n")
    for (i in seq_len(nrow(f))) cat(sprintf("FAIL [%s] %s: %s\n", f$group[i], f$test[i], f$detail[i]))
    quit(save = "no", status = 1)
  }
  invisible(DBI::dbExecute(con, "RELEASE dataset_meta_cli"))
}

## every argument of a key=value mode must hold an "="
need_kv = function(kv, fmt) if (any(!grepl("=", kv, fixed = TRUE))) stop("not ", fmt, ": ", paste(kv[!grepl("=", kv, fixed = TRUE)], collapse = " "), call. = FALSE)

if (mode == "set") {
  if (length(args) < 3) stop("set: need key=value ...")
  kv = args[-(1:2)]
  need_kv(kv, "key=value")
  m = setNames(as.list(sub("^[^=]*=", "", kv)), sub("=.*", "", kv, perl = TRUE))   # values verbatim (lists: a|b|c)
  guarded(function() t2_write_meta(con, meta = m))
} else if (mode == "set-json") {
  if (length(args) != 4 || !startsWith(args[4], "@")) stop("set-json: need  key @file.json")
  if (!args[3] %in% c("tte_variables", "references")) stop("set-json: only tte_variables and references hold JSON, not ", args[3])
  f = substring(args[4], 2)
  if (!file.exists(f)) stop("no such json file: ", f)
  js = paste(readLines(f, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  if (identical(args[3], "references")) guarded(function() t2_write_meta(con, meta = list(references = js)))   # validated by t2_references_norm
  else guarded(function() t2_write_meta(con, tte = js))
} else if (mode == "type-label") {
  if (length(args) < 3) stop("type-label: need type=label ...")
  kv = args[-(1:2)]
  need_kv(kv, "type=label")
  guarded(function() t2_write_types(con, data.frame(type = sub("=.*", "", kv), label = sub("^[^=]*=", "", kv), stringsAsFactors = FALSE), allow_new = FALSE))
  m = DBI::dbGetQuery(con, "SELECT type, label FROM types ORDER BY key")
  for (i in seq_len(nrow(m))) cat(sprintf("%-18s \"%s\"\n", m$type[i], m$label[i]))
  quit(save = "no", status = 0)
}
if (mode == "type-fill") {
  if (length(args) < 3) stop("type-fill: need type=na|zero|floor ...")
  kv = args[-(1:2)]
  need_kv(kv, "type=fills")
  ty = sub("=.*", "", kv); fo = vapply(sub("^[^=]*=", "", kv), t2_fill_options_check, "", USE.NAMES = FALSE)   # validated words, canonical order
  sp = if ("sparse" %in% DBI::dbListTables(con)) DBI::dbGetQuery(con, "SELECT type, sparse FROM sparse") else data.frame(type = character(0), sparse = integer(0))
  unk = setdiff(ty, DBI::dbGetQuery(con, "SELECT type FROM types")$type)
  if (length(unk)) stop("type-fill: unknown type(s): ", paste(unk, collapse = ", "))
  bad = ty[fo != "na" & !(as.integer(sp$sparse[match(ty, sp$type)]) %in% 0L)]   # no sparse row = sparse
  if (length(bad)) stop("type-fill: ", paste(bad, collapse = ", "), " is sparse (or has no sparse row): a sparse type has no fill, only na (contract: fill_options only on sparse = 0 types)")
  guarded(function() t2_write_types(con, data.frame(type = ty, fill_options = fo, stringsAsFactors = FALSE), allow_new = FALSE))
  m = DBI::dbGetQuery(con, "SELECT type, fill_options FROM types ORDER BY key")
  for (i in seq_len(nrow(m))) cat(sprintf("%-18s %s\n", m$type[i], if (is.na(m$fill_options[i])) "(na)" else m$fill_options[i]))
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
