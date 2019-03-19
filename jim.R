library(tidyverse)
library(sqldf)

## set finite my.limit for testing, set to Inf for production

db = 'tcga.db'

sqldf('select name from sqlite_master', db = db)

sqldf('select * from sqlite_master', db = db)

sqldf('select * from samples limit 5', db = db)

sqldf('select * from probes limit 5', db = db)

sqldf('select * from probes where probe = "ABCA1"', db = db)

sqldf('select * from tcgai limit 5', db = db)

sqldf('select * from tcgacati limit 5', db = db)

sqldf('select distinct type from tcgacati', db = db)

sqldf('select * from tcgacati where type = "immune_subtype" limit 5', db = db)

sqldf('select * from tcgacat where type = "immune_subtype" limit 5', db = db)

sqldf('select * from tcgacat limit 5', db = db)

sqldf('select sql from sqlite_master where name = "tcgacat"', db = db)

sqldf('select sql from sqlite_master where name = "tcga"', db = db)

sqldf('select * from clin limit 2', db = db)

sqldf('select * from clinpheno limit 2', db = db)

sqldf( 'select distinct Subtype_Selected from clinpheno where tumtype = "STAD"', db = db)

foo = sqldf('select * from tcga where probe in ( "ABCA1", "CD8A")', db = db)

foo %>% distinct( sample, probe, type, .keep_all = TRUE ) %>% spread(probe, value) %>% head






