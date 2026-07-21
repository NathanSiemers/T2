
my_immune = read_tsv('Data/Subtype_Immune_Model_Based.txt.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        mutate(sample = make.unique(sample, sep = '_') ) %>%
            gather( probe, value, -sample ) %>%
                mutate( type = 'immune_subtype' ) %>%
                    select( sample, probe, value, type )
my_immune

tablemaker(my_immune, categorical = TRUE, sparse = FALSE)
my_immune = NULL; gc()

