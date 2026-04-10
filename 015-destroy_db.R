## One-time database destruction before a full rebuild
## Only sourced by 00-master.R
if (!mysql) {
  cat("Destroying old database...\n")
  try(file.remove('tcga.db'), silent = TRUE)
  file.create('tcga.db')
}
