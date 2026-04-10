## install_packages.R - install all R packages needed for this project
## Usage:
##   Rscript install_packages.R               # SQLite only (default)
##   Rscript install_packages.R --with-mysql   # also install RMySQL

args = commandArgs(trailingOnly = TRUE)

cran_packages = c(
  "DBI",
  "RSQLite",
  "tidyverse",       # includes dplyr, ggplot2, tidyr, readr, purrr, forcats, stringr, tibble
  "readxl",
  "sqldf",
  "data.table",
  "ggthemes",
  "viridis",
  "shiny",
  "shinythemes",
  "shinycssloaders",
  "rmarkdown",
  "UCSCXenaTools",
  "devtools"
)

## install CRAN packages
install_if_missing = function(pkgs) {
  missing = pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
  if (length(missing) > 0) {
    cat("Installing:", paste(missing, collapse = ", "), "\n")
    install.packages(missing)
  } else {
    cat("All packages already installed.\n")
  }
}

install_if_missing(cran_packages)

## MySQL backend (optional, has system-level dependencies)
if ("--with-mysql" %in% args) {
  cat("\nInstalling MySQL support...\n")
  install_if_missing("RMySQL")
} else {
  cat("\nSkipping RMySQL (not needed for SQLite).\n")
  cat("  To install later: Rscript install_packages.R --with-mysql\n")
}

## estimate package is NOT required — pre-computed scores are in ESTIMATE_copy.csv
## To regenerate from scratch: install.packages("estimate", repos = "http://r-forge.r-project.org")

cat("\nDone.\n")
