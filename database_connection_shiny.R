mysql = FALSE
mysqldb = 'prod'

library(DBI)
if( ! mysql ) {
    db = 'tcga.db'
    con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RO )
} else {
    if ( ! require( 'RMySQL' ) ) {  install.packages('RMySQL')  }
    library(RMySQL)
    if( mysqldb == 'dev') {
        con = RMySQL::dbConnect (
            drv       = RMySQL::MySQL(),
            dbname    = "pancan2018dev",
            host      = Sys.getenv("MYSQL_HOST", "localhost"),
            port      = 3306,
            username  = Sys.getenv("MYSQL_READER_USER", "reader"),
            password  = Sys.getenv("MYSQL_READER_PASSWORD"))
    } else {
        con = RMySQL::dbConnect (
            drv       = RMySQL::MySQL(),
            dbname    = "pancan2018",
            host      = Sys.getenv("MYSQL_HOST", "localhost"),
            port      = 3306,
            username  = Sys.getenv("MYSQL_READER_USER", "reader"),
            password  = Sys.getenv("MYSQL_READER_PASSWORD"))
    }
}
