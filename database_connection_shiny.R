mysql = FALSE
mysqldb = 'prod'

library(DBI)

## Open a read-only connection to a specific dataset db file.
## (Multi-dataset support: the app opens one of these per selected dataset.)
open_dataset_con = function(dbfile = 'tcga.db') {
    RSQLite::dbConnect(RSQLite::SQLite(), dbname = dbfile,
                       flags = RSQLite::SQLITE_RO)
}

if( ! mysql ) {
    ## Default connection points at the canonical TCGA db so that sourcing
    ## lib.R at startup (which builds the default choice-lists) still works
    ## unchanged. The app re-points to the selected dataset via the bundle.
    db = 'tcga.db'
    con = open_dataset_con(db)
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
