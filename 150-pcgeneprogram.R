
################################################################
## there's a file corruption here, skipping for now
## my_pc_gene_program = read_tsv('Data/Pancan12_GenePrograms_drugTargetCanon_in_Pancan33.tsv.gz',
##     trim_ws = TRUE, n_max = my.limit ) %>%
##         gather( probe, value, -sample ) %>%
##         mutate(type = 'pc_gene_program') %>%
##             select( sample, probe, value, type )
## my_pc_gene_program
## tablemaker(my_pc_gene_program)
## my_pc_gene_program = NULL; gc()
################################################################
