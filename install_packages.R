## install_packages.R - install all R packages needed for this project
## Run this once after cloning: Rscript install_packages.R

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

## packages only needed if using MySQL backend (mysql = TRUE)
mysql_packages = c("RMySQL")

## Bioconductor packages
bioc_packages = c("estimate")

## install CRAN packages
install_if_missing = function(pkgs) {
  missing = pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
  if (length(missing) > 0) {
    cat("Installing:", paste(missing, collapse = ", "), "\n")
    install.packages(missing)
  } else {
    cat("All CRAN packages already installed.\n")
  }
}

install_if_missing(cran_packages)

## Bioconductor
if (!requireNamespace("estimate", quietly = TRUE)) {
  cat("Installing estimate from R-Forge...\n")
  install.packages("estimate", repos = "http://r-forge.r-project.org", dependencies = TRUE)
}

cat("\nOptional (MySQL backend only):\n")
cat("  install.packages('RMySQL')\n")

cat("\nDone. Verify with: sapply(c(", paste0('"', cran_packages, '"', collapse = ', '), "), require, character.only = TRUE)\n")
