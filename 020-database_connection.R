library(DBI)

try(dbDisconnect(con), silent = TRUE)

get_db_con = function(){
  if( ! mysql ) {
    db = 'tcga.db'
    RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RW )
  } else {
    if ( ! require( 'RMySQL' ) ) {  install.packages('RMySQL')  }
    library(RMySQL)
    if( mysqldb == 'dev') {
      RMySQL::dbConnect (
        drv       = RMySQL::MySQL(),
        dbname    = "pancan2018dev",
        host      = Sys.getenv("MYSQL_HOST", "localhost"),
        port      = 3306,
        username  = Sys.getenv("MYSQL_USER", "admin"),
        password  = Sys.getenv("MYSQL_PASSWORD"))
    } else {
      RMySQL::dbConnect (
        drv       = RMySQL::MySQL(),
        dbname    = "pancan2018",
        host      = Sys.getenv("MYSQL_HOST", "localhost"),
        port      = 3306,
        username  = Sys.getenv("MYSQL_USER", "admin"),
        password  = Sys.getenv("MYSQL_PASSWORD"))
    }
  }}

con = get_db_con()
