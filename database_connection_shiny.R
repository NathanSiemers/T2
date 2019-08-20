mysql = TRUE
mysqldb = 'prod'
sqldestroy = FALSE

library(DBI)
if( ! mysql ) {
    db = 'tcga.db'
    con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RW )
} else {
    ##library(pool)
    if ( ! require( 'RMySQL' ) ) {  install.packages('RMySQL')  }
    library(RMySQL)
    if( mysqldb == 'dev') {
##        con <- dbPool(
            con = RMySQL::dbConnect (
            drv       = RMySQL::MySQL(),
            dbname    = "pancan2018dev",
            host      = "pancan2018dev.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
            port      = 3306,
            username  = "reader",
            password  = "Readeruser19")
    } else {
    ##    con <- dbPool(
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
## if(mysql){
##     onStop(function() {
##         poolClose(pool)
##     })
## }
