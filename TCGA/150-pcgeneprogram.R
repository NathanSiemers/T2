
my_pc_gene_program = read_tsv('Data/Pancan12_GenePrograms_drugTargetCanon_in_Pancan33.tsv.gz',
                               trim_ws = TRUE, n_max = 10 )
my_pc_gene_program


my_pc_gene_program = read_tsv('Data/Pancan12_GenePrograms_drugTargetCanon_in_Pancan33.tsv.gz',
                              trim_ws = TRUE, n_max = my.limit ) %>% 
    rename(probe = sample) %>%
    gather( sample, value, -probe) %>%
    mutate( type = "pc_gene_program" ) %>%
    select( sample, probe, value, type )

my_pc_gene_program

## very continuous data sparse = FALSE
tablemaker(my_pc_gene_program, sparse = FALSE)
my_pc_gene_program = NULL; gc()




## old

################################################################
## there's a file corruption here, skipping for now
## my_pc_gene_program = read_tsv('Data/Pancan12_GenePrograms_drugTargetCanon_in_Pancan33.tsv.gz',
##      trim_ws = TRUE, n_max = my.limit ) %>%
##          gather( probe, value, -sample ) %>%
##          mutate(type = 'pc_gene_program') %>%
##              select( sample, probe, value, type )
## my_pc_gene_program
