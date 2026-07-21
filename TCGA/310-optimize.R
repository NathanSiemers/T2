sqlvacuum = TRUE
if( ! mysql) {
      if( sqlvacuum ) {
	    system(paste0('sqlite3 ', Sys.getenv('TCGA_DB','../tcga.db'), ' "VACUUM;"'))
	}
  } else {
      if( optimize ) {
          dbExecute(con, 'optimize table tcgai, tcgacati, probes, samples')
      }
  }











