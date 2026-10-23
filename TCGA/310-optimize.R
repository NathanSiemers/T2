sqlvacuum = TRUE
if( ! mysql) {
      if( sqlvacuum ) {
	    system2('sqlite3', c(shQuote(Sys.getenv('TCGA_DB','../tcga.db')), shQuote('VACUUM;')))   # quoted: a path may hold blanks or shell characters
	}
  } else {
      if( optimize ) {
          dbExecute(con, 'optimize table tcgai, tcgacati, probes, samples')
      }
  }











