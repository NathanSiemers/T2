library(sqldf)
source("010-settings.R", echo = TRUE)
source("020-database_connection.R", echo = TRUE)
source("030-good.functions.R", echo = TRUE)
source('gitr.R', echo = TRUE)
db = 'tcga.db'

################################################################

sqldf('select * from tcgas limit 1', db = db)


sqldf('select * from tcgas where type = "murtest" limit 5', db = db)


sqldf('select * from tcga limit 1', db = db)

sqldf('select * from tcga where tumtype = "LAML" limit 5', db = db)

out = sqldf('select * from tcga where type = "muttest"', db = db)
dim(out)

with(out, table(type, tumtype))

sqldf('select * from tcga where type = "muttest" and tumtype = "LAML" limit 5', db = db)

table(sqldf('select tumtype from tcga where type = "mut"', db = db))

table(sqldf('select tumtype from tcga where type = "cnv"', db = db))


       
