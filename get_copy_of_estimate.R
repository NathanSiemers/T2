library(sqldf)
db = "../tcga.db"
sqldf('select * from types', db = db)
estimate = sqldf("select * from tcgas where type = 'estimate'", db = db); dim(estimate)
head(estimate)
write.csv(estimate, file = "ESTIMATE_copy.csv")
