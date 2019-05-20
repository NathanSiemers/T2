library(sqldf)
db = 'tcga.db'

sqldf('select * from probes limit 3', db = db)
sqldf('select * from samples limit 3', db = db)
sqldf('select * from tcgai limit 3', db = db)

tail(sqldf('select * from probes', db = db))

