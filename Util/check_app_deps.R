################################################################
## Diagnostic script: run on the target machine to check if
## the Shiny app has everything it needs to start
## Usage: Rscript Util/check_app_deps.R

cat("=== T2 Shiny App Dependency Check ===\n\n")
ok = TRUE

## 1. Required files
cat("--- Required files ---\n")
required = c("global.R", "app.R", "database_connection_shiny.R",
             "lib.R", "gitr.R", "tcga.db")
for (f in required) {
  exists = file.exists(f)
  size = if (exists) file.info(f)$size else NA
  status = if (exists) sprintf("OK (%s)", format(size, big.mark = ",")) else "MISSING"
  if (!exists) ok = FALSE
  cat(sprintf("  %-35s %s\n", f, status))
}

## 2. Required R packages
cat("\n--- Required packages ---\n")
pkgs = c("shiny", "shinythemes", "shinycssloaders", "DBI", "RSQLite",
         "sqldf", "ggplot2", "ggthemes", "viridis", "tidyverse",
         "rmarkdown", "readxl")
for (p in pkgs) {
  avail = requireNamespace(p, quietly = TRUE)
  if (!avail) ok = FALSE
  cat(sprintf("  %-25s %s\n", p, if (avail) "OK" else "MISSING"))
}

## 3. Database check
cat("\n--- Database check ---\n")
if (file.exists("tcga.db")) {
  tryCatch({
    con = RSQLite::dbConnect(RSQLite::SQLite(), "tcga.db", flags = RSQLite::SQLITE_RO)
    tables = DBI::dbListTables(con)
    cat(sprintf("  Tables found: %d\n", length(tables)))
    needed = c("clinpheno", "tcgai", "tcgacati", "probes", "samples",
               "types", "allprobes", "cohorts", "tested", "probe_types")
    for (t in needed) {
      exists = t %in% tables
      if (!exists) ok = FALSE
      cat(sprintf("  %-25s %s\n", t, if (exists) "OK" else "MISSING"))
    }
    DBI::dbDisconnect(con)
  }, error = function(e) {
    cat(sprintf("  ERROR connecting: %s\n", e$message))
    ok <<- FALSE
  })
} else {
  cat("  tcga.db not found!\n")
}

## 4. Try sourcing the startup chain
cat("\n--- Startup chain ---\n")
tryCatch({
  source("global.R")
  cat("  global.R: OK\n")
}, error = function(e) { cat(sprintf("  global.R: FAIL - %s\n", e$message)); ok <<- FALSE })

tryCatch({
  source("database_connection_shiny.R")
  cat("  database_connection_shiny.R: OK\n")
}, error = function(e) { cat(sprintf("  database_connection_shiny.R: FAIL - %s\n", e$message)); ok <<- FALSE })

tryCatch({
  source("lib.R")
  cat("  lib.R: OK\n")
}, error = function(e) { cat(sprintf("  lib.R: FAIL - %s\n", e$message)); ok <<- FALSE })

cat(sprintf("\n=== %s ===\n", if (ok) "ALL CHECKS PASSED" else "ISSUES FOUND"))
