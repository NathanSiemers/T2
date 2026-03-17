sqlvacuum = TRUE
if( ! mysql) {
      if( sqlvacuum ) {
	    system('sqlite3 tcga.db "VACUUM;"')
	}
  } else {
      if( optimize ) {
          dbExecute(con, 'optimize table tcgai, tcgacati, probes, samples')
      }
  }











