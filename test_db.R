library(sqldf)

db = 'tcga.db'

sqldf('select distinct sample_type from clin', db = db)
