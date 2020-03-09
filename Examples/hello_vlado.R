library(tidyverse)
library(DBI)
## this is the magic database connection string
## read only access
## no problems with sharing this with others
con = RMySQL::dbConnect (
    drv       = RMySQL::MySQL(),
    dbname    = "pancan2018",
    host      = "pancan2018.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
    port      = 3306,
    username  = "reader",
    password  = "Readeruser19"  )
library(sqldf)

sqldf( 'show tables', con = con)

sqldf( 'select * from cnv limit 10', con = con)

