
## massage the cohorts table
clintmpclean  = dbGetQuery(con, 'select tumtype, cohort from clin')  %>% drop_na %>% distinct
clintmpclean$string = with( clintmpclean, paste(cohort, '(', tumtype, ')' ) )
clintmpclean = clintmpclean %>% rename(cohort = tumtype, lcohort = cohort, cohortstring = string)

try(dbRemoveTable(con, 'cohorts'))
dbWriteTable(con, 'cohorts', clintmpclean, row.names = FALSE)
dbGetQuery(con, 'select * from cohorts')
