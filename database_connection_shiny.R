mysql = TRUE
mysqldb = 'prod'

library(DBI)
if( ! mysql ) {
    db = 'tcga.db'
    if( sqldestroy ) {
        print("destroying old sql database")
        try(system( paste("rm", db) ) , silent = TRUE)
        system('touch tcga.db')
        ##dbExecute( 'attach "tcga.db" as new' )
    }
    con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RW )
} else {
    if ( ! require( 'RMySQL' ) ) {  install.packages('RMySQL')  }
    library(RMySQL)
    if( mysqldb == 'dev') {
       con = RMySQL::dbConnect (
        drv       = RMySQL::MySQL(),
        dbname    = "pancan2018dev",
        host      = "pancan2018dev.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
        port      = 3306,
        username  = "reader",
           password  = "Readeruser19")
   } else {
       con = RMySQL::dbConnect (
           drv       = RMySQL::MySQL(),
           dbname    = "pancan2018",
           host      = "pancan2018.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
           port      = 3306,
           username  = "reader",
           password  = "Readeruser19")
   }
}


##install.packages('pool')
##library(pool)
## con <- dbPool(
##   drv = RSQLite::SQLite(),
##   dbname = db
## )
## onStop(function() {
##   poolClose(pool)
## })
