## dataset_meta.R -- read or set keys of a dataset's dataset_meta table.
##   Rscript dataset_meta.R show <db>
##   Rscript dataset_meta.R set  <db> key=value [key=value ...]      (lists: a|b|c)
## For the keys and their meaning see dataset_registry.R (roles, defaults) and
## t2_presets.R (source_col, sources, source_labels, source_descriptions).
## Never run against a SERVED database file: deploy by a new directory.
args = commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: Rscript dataset_meta.R show|set <db> [key=value ...]")
ro = identical(args[1], "show")
con = DBI::dbConnect(RSQLite::SQLite(), args[2], flags = if (ro) RSQLite::SQLITE_RO else RSQLite::SQLITE_RW)
on.exit(DBI::dbDisconnect(con))
if (!ro) {
  if (!"dataset_meta" %in% DBI::dbListTables(con)) stop("no dataset_meta table in ", args[2], " (the canonical TCGA db has none; its roles are fixed in dataset_registry.R)")
  for (kv in args[-(1:2)]) {
    k = sub("=.*", "", kv); v = sub("^[^=]*=", "", kv)
    DBI::dbExecute(con, "DELETE FROM dataset_meta WHERE key = ?", params = list(k))
    DBI::dbExecute(con, "INSERT INTO dataset_meta(key, value) VALUES (?, ?)", params = list(k, v))
  }
}
m = DBI::dbGetQuery(con, "SELECT key, value FROM dataset_meta")
for (i in seq_len(nrow(m))) cat(sprintf("%-22s %s\n", m$key[i], m$value[i]))
