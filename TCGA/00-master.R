## Config is env-overridable so the pipeline can be run against a SCRATCH db for
## testing without ever touching the live tcga.db. Defaults reproduce the
## production build exactly (TESTING off, full data, ../tcga.db).
##   TCGA_TESTING=TRUE  TCGA_TESTINGLINES=2000  TCGA_DB=/path/scratch.db
TESTING = as.logical(Sys.getenv('TCGA_TESTING', 'FALSE'))
TESTINGLINES = local({ v <- Sys.getenv('TCGA_TESTINGLINES', ''); if (nzchar(v)) as.numeric(v) else Inf })
mysql  = FALSE
mysqldb = 'prod'
download = FALSE
optimize = FALSE
xena.force = FALSE
Sys.setenv("VROOM_CONNECTION_SIZE" = 1e9)
## Run from THIS script's own directory (TCGA/) so pipeline-relative paths —
## sibling scripts, Data/, ../tcga.db, ../gitr.R — all resolve. Works for
## `Rscript TCGA/00-master.R` from anywhere; for interactive use, setwd() into
## TCGA/ before sourcing.
local({
  f <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(f)) setwd(dirname(normalizePath(sub('^--file=', '', f[1]))))
})

## ---- build to a "<final>.building" file, promote atomically after tests ----
## The whole pipeline writes to <final>.building; the live db is untouched until
## the freshly built db passes the SQL suite, then a same-filesystem rename
## swaps it in. A failed build leaves the live db exactly as it was.
.final_db = Sys.getenv('TCGA_DB', '../tcga.db')
.build_db = paste0(.final_db, '.building')
Sys.setenv(TCGA_DB = .build_db)          # 015/020/280/310/validation all target this
for (.s in c('', '-wal', '-shm')) try(file.remove(paste0(.build_db, .s)), silent = TRUE)
message('Building to ', .build_db, '  (live ', .final_db, ' stays until tests pass)')

promote_db = function(build, final) {
  cc = DBI::dbConnect(RSQLite::SQLite(), build)          # fold WAL into main file
  try(DBI::dbExecute(cc, 'PRAGMA wal_checkpoint(TRUNCATE)'), silent = TRUE)
  DBI::dbDisconnect(cc)
  for (sfx in c('-wal', '-shm')) {
    try(file.remove(paste0(build, sfx)), silent = TRUE)
    try(file.remove(paste0(final, sfx)), silent = TRUE) # stale sidecars of old db
  }
  file.rename(build, final)                              # atomic (same filesystem)
}

## comment out the line below if you don't want to delete
## the old db and start from scratch
source ('015-destroy_db.R', echo = TRUE, max.deparse.length = Inf)
##
source ('020-database_connection.R', echo = TRUE, max.deparse.length = Inf)
source ('030-good.functions.R',echo = TRUE, max.deparse.length = Inf)
source( 'tablemaker.R')
source( 'ensure_con.R')

## helper: run a build step, reconnecting to db if needed
run = function(script) {
  ensure_con()
  source(script, echo = TRUE, max.deparse.length = Inf)
}
################################################################

if(download) run('035-download.R')

run('040-create_schema.R')
run('050-create_early_indexes.R')
run('060-clinical.R')
run('070-rna.R')
run('080-geography.R')
##run('090-exongeo.R')
##run('100-exonrna.R')
run('110-cnv.R')
run('120-cnc.R')
run('125-rppa.R')
run('130-mut.R')
run('135-viral.R')
run('140-urna.R')
run('150-pcgeneprogram.R')
run('160-rabit.R')
run('170-hrd.R')
run('180-immunescore.R')
run('190-molecsubtype.R')
run('200-immunemodel.R')
run('210-fmut.R')
run('220-cnvsegments.R')
run('230-clinpheno.R')
run('240-clinvars-into-allprobes.R')
run('255-cohorts_table.R')
run('260-tmb.R')
run('270-estimate.R')
run('275-MSI.R')
## create views before signatures (signatures need the tcga view)
run('300-final_indexing.R')
run('250-create_views.R')
## add_signatures_to_db.R will break with small tests, so do this near the end
run('280-add_signatures_to_db.R')
## rebuild views + probe_types to pick up signature probes
run('300-final_indexing.R')
run('250-create_views.R')
run('290-record_environment.R')
run('295-type_descriptions.R')
if(optimize) run('310-optimize.R')
## ---- SQL validation against the freshly built (.building) db --------------
## Reusable suite (../sql_tests.R). Pre-source gitr + dataset_registry from the
## common root so sql_tests' own load guards skip.
source('../gitr.R')
source('../dataset_registry.R')
source('../sql_tests.R')
try(dbDisconnect(con), silent = TRUE)         # release the build's RW handle
.tcga_tests = run_sql_tests(.build_db, 'TCGA')
for (.db in list.files('../datasets', pattern='\\.db$', full.names=TRUE)) {
  try(run_sql_tests(.db))
}

## ---- atomic promote: swap the new db in ONLY if it passed -----------------
if (isTRUE(.tcga_tests$ok)) {
  promote_db(.build_db, .final_db)
  message('PROMOTED ', .build_db, ' -> ', .final_db)
  ## regenerate the schema ERD from the promoted canonical db (repo root)
  if (identical(.final_db, '../tcga.db'))
    local({ owd <- getwd(); on.exit(setwd(owd)); setwd('..'); source('Util/generate_erd.R') })
} else {
  warning('SQL tests FAILED — live ', .final_db,
          ' left untouched; inspect ', .build_db)
}

sessionInfo()
