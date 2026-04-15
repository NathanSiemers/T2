################################################################
## Generate ERD (Entity Relationship Diagram) as Mermaid markdown
## Run: Rscript Util/generate_erd.R
## Output: schema_erd.md (renders on GitHub)

library(DBI)

con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = "tcga.db", flags = RSQLite::SQLITE_RO)

## core tables (exclude tmp tables, env tables, tmptable)
skip = c("allprobestmp", "probestmp", "samplestmp", "tcgaitmp", "tcgacatitmp",
         "tmptable", "env_checksums", "env_env", "env_packages", "env_platform")

tables = dbGetQuery(con, "SELECT name, type FROM sqlite_master
                          WHERE type IN ('table', 'view') ORDER BY type, name")
tables = tables[!(tables$name %in% skip), ]

## get columns for each table
schema = list()
for (tbl in tables$name) {
  cols = dbListFields(con, tbl)
  schema[[tbl]] = list(type = tables$type[tables$name == tbl], cols = cols)
}

## get indexes
indexes = dbGetQuery(con, "SELECT name, tbl_name, sql FROM sqlite_master
                           WHERE type = 'index' AND sql IS NOT NULL ORDER BY tbl_name")

dbDisconnect(con)

################################################################
## Build Mermaid ERD

lines = c(
  "# Database Schema (ERD)",
  "",
  sprintf("Generated: %s", Sys.time()),
  "",
  "```mermaid",
  "erDiagram"
)

## tables with many clinical columns — show only key cols
truncate_at = 10
for (tbl in names(schema)) {
  s = schema[[tbl]]
  lines = c(lines, sprintf("    %s {", tbl))
  cols_to_show = if (length(s$cols) > truncate_at) {
    c(s$cols[1:truncate_at], sprintf("_plus_%d_more_columns", length(s$cols) - truncate_at))
  } else {
    s$cols
  }
  for (col in cols_to_show) {
    lines = c(lines, sprintf("        string %s", col))
  }
  lines = c(lines, "    }")
}

## define relationships
lines = c(lines, "",
  "    %% Core data relationships",
  "    samples ||--o{ tcgai : samplekey",
  "    probes ||--o{ tcgai : probekey",
  "    samples ||--o{ tcgacati : samplekey",
  "    probes ||--o{ tcgacati : probekey",
  "    types ||--o{ tcgai : type",
  "    types ||--o{ tcgacati : type",
  "",
  "    %% Lookup tables",
  "    probes ||--o{ probe_types : probekey",
  "    probes ||--o{ allprobes : probe",
  "    types ||--o{ datatypes : type",
  "    types ||--o{ nosuffix : type",
  "    types ||--o{ tested : type",
  "",
  "    %% Clinical",
  "    clin ||--|| clinpheno : sample",
  "    clinpheno ||--o{ cohorts : tumtype",
  "",
  "    %% Views (dense numeric)",
  "    probe_types }o--|| tcgas : \"probekey+type\"",
  "    tested }o--|| tcgas : \"type+sample\"",
  "    tcgai }o--|| tcgas : \"probekey+type+samplekey\"",
  "    clinpheno ||--o{ tcga : sample",
  "    tcgas }o--|| tcga : \"sample+probe\"",
  "",
  "    %% Views (simple categorical)",
  "    tcgacati }o--|| tcgacats : \"samplekey+probekey\"",
  "    clinpheno ||--o{ tcgacat : sample",
  "    tcgacati }o--|| tcgacat : \"samplekey+probekey\"",
  "",
  "    %% Mutation-specific",
  "    mutation ||--o{ mutationsamples : sample",
  "    cnv ||--o{ geo : gene"
)

lines = c(lines, "```", "")

## add index summary
lines = c(lines, "## Indexes", "", "| Table | Index | Columns |", "|-------|-------|---------|")
for (i in seq_len(nrow(indexes))) {
  cols = sub(".*\\((.*)\\)", "\\1", indexes$sql[i])
  lines = c(lines, sprintf("| %s | %s | %s |", indexes$tbl_name[i], indexes$name[i], cols))
}

## add table sizes
lines = c(lines, "", "## Table Sizes", "")
con2 = RSQLite::dbConnect(RSQLite::SQLite(), dbname = "tcga.db", flags = RSQLite::SQLITE_RO)
lines = c(lines, "| Table | Type | Rows | Columns |", "|-------|------|-----:|--------:|")
for (tbl in names(schema)) {
  s = schema[[tbl]]
  ## skip row counts for views (too slow on large dense views)
  if (s$type == "view") {
    n_str = "(view)"
  } else {
    n = tryCatch(
      DBI::dbGetQuery(con2, sprintf("SELECT count(*) FROM \"%s\"", tbl))[[1]],
      error = function(e) NA
    )
    n_str = if (is.na(n)) "?" else formatC(n, format = "d", big.mark = ",")
  }
  lines = c(lines, sprintf("| %s | %s | %s | %d |",
    tbl, s$type, n_str, length(s$cols)))
}
DBI::dbDisconnect(con2)

lines = c(lines, "")
writeLines(lines, "schema_erd.md")
cat("ERD written to schema_erd.md\n")
