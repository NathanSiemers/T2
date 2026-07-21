rundate = Sys.time()

env = data.frame(
    rundate = rundate,
    variable = names(Sys.getenv()),
    value = as.character(Sys.getenv())
)

session = devtools::session_info()

packages = data.frame(session$packages) ; packages$rundate = rundate

platform = as.data.frame((unclass(session$platform))); platform$rundate = rundate

md5 = as.data.frame(tools::md5sum(paste0('Data/', list.files('Data') ) ))
md5$file = rownames(md5); rownames(md5) = NULL
colnames(md5) = c('md5', 'file')
head(md5)

datachecksums = cbind(
    rundate = rundate,
    md5
    )

head(datachecksums)
colnames(datachecksums)


dbWriteTable( con, "env_checksums",  datachecksums, row.names = FALSE, overwrite = TRUE )
dbWriteTable( con, "env_env",  env, row.names = FALSE, overwrite = TRUE )
dbWriteTable( con, "env_packages",  packages, , row.names = FALSE, overwrite = TRUE )
dbWriteTable( con, "env_platform",  platform, row.names = FALSE, overwrite = TRUE )

