
################################################################
## geography

my_geo = read_tsv('hugo_gencode_good_hg19_V24lift37_probemap',
    trim_ws = TRUE, n_max = my.limit )
my_geo
##try(dbRemoveTable(con, 'geo'), silent = TRUE)
dbWriteTable(con, 'geo', my_geo, overwrite = TRUE, row.names = FALSE)

## need to keep this around now
##my_geo = NULL; gc()

################################################################
