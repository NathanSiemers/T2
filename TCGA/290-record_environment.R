rundate = Sys.time()

## only what describes the run (R, locale, time zone, user, T2_ / TCGA_ settings): the environment of a
## build host also holds credentials, and this table ships inside the served database. Any name that
## looks like a secret is dropped even when the allowlist matches it.
.env_all = Sys.getenv()
.env_keep = grepl('^(R_|TZ$|LANG|LC_|HOME$|USER$|PATH$|T2_|TCGA_)', names(.env_all)) &
            (!grepl('KEY|TOKEN|PASS|SECRET|PAT|CRED', names(.env_all), ignore.case = TRUE) | names(.env_all) == 'PATH')   # PATH itself holds no secret
env = data.frame(
    rundate = rundate,
    variable = names(.env_all)[.env_keep],
    value = as.character(.env_all)[.env_keep]
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

