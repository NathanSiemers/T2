TESTING = FALSE
TESTINGLINES = Inf
mysql  = FALSE
mysqldb = 'prod'
download = FALSE
optimize = FALSE
xena.force = FALSE
Sys.setenv("VROOM_CONNECTION_SIZE" = 1e9)
source ('015-destroy_db.R', echo = TRUE, max.deparse.length = Inf)
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
run('240-allprobetable.R')
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
if(optimize) run('310-optimize.R')


sessionInfo()
