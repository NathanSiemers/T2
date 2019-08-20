## exon geography

my_geoexon = read_tsv('unc_v2_exon_hg19_probe_TCGA',
    trim_ws = TRUE, n_max = my.limit )
my_geoexon
my_geoexon = plyr::ddply( my_geoexon, ~ gene, function(x) {
    if( x$strand[[1]] == '-' ){
        my_decr = TRUE
    } else {
        my_decr = FALSE
    }
    x = x[ order(x$chromStart, decreasing = my_decr), ]
    x$probe = paste0( x$gene, '_exon_', seq.int(nrow(x))  )
    x
}) %>% as_tibble
my_geoexon        
    
dbWriteTable(con, 'geoexon', my_geoexon, overwrite = TRUE, row.names = FALSE)

