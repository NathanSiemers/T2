## One-time database destruction before a full rebuild
## Only sourced by 00-master.R
if (!mysql) {
  cat("Destroying old database...\n")
  .dbp = Sys.getenv('TCGA_DB', '../tcga.db')
  try(file.remove(.dbp), silent = TRUE)
  file.create(.dbp)
}
