## ensure_con() - reconnect to database if connection has dropped
## source this file in any script that needs a database connection

ensure_con = function() {
  if (!exists("con", envir = .GlobalEnv) || !DBI::dbIsValid(con)) {
    cat("Reconnecting to database...\n")
    con <<- get_db_con()
  }
  invisible(con)
}
