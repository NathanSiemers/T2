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

## generate PDF or HTML if pandoc is available
if (Sys.which("pandoc") != "") {
  ## build a print-friendly version (mermaid blocks don't render in pandoc)
  print_lines = lines
  mermaid_start = grep("^```mermaid", print_lines)
  mermaid_end = grep("^```$", print_lines)
  if (length(mermaid_start) > 0 && length(mermaid_end) > 0) {
    mermaid_end = mermaid_end[mermaid_end > mermaid_start[1]][1]
    block = print_lines[(mermaid_start[1]+1):(mermaid_end-1)]
    rels = block[grepl("\\|", block) & !grepl("^\\s*%%", block)]
    rels = trimws(rels)
    replacement = c(
      "## Entity Relationships",
      "*(Interactive diagram renders on GitHub — see schema_erd.md)*",
      "", "```", rels, "```"
    )
    print_lines = c(print_lines[1:(mermaid_start[1]-1)], replacement,
                    print_lines[(mermaid_end+1):length(print_lines)])
  }
  tmp_md = tempfile(fileext = ".md")
  writeLines(print_lines, tmp_md)
  ## try PDF first (needs LaTeX), fall back to standalone HTML
  pdf_cmd = sprintf('pandoc "%s" -o schema_erd.pdf -V geometry:margin=1in -V fontsize=10pt 2>/dev/null', tmp_md)
  pdf_ok = suppressWarnings(system(pdf_cmd, ignore.stdout = TRUE) == 0)
  if (pdf_ok && file.exists("schema_erd.pdf")) {
    cat("PDF written to schema_erd.pdf\n")
  } else {
    try(file.remove("schema_erd.pdf"), silent = TRUE)
    html_cmd = sprintf('pandoc "%s" -o schema_erd.html -s --metadata title="Database Schema" 2>/dev/null', tmp_md)
    system(html_cmd, ignore.stdout = TRUE)
    if (file.exists("schema_erd.html")) cat("HTML written to schema_erd.html\n")
  }
  unlink(tmp_md)
}
