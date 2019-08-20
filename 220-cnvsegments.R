################################################################
## copy number segments - make a dedicated table

my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnv

##try(dbRemoveTable(con, 'cnv'), silent = TRUE)
dbWriteTable(con, 'cnv', my_cnv, overwrite = TRUE, row.names = FALSE)
my_cnv = NULL; gc()


