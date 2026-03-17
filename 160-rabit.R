my_rabit = read_tsv('Data/RABIT__pancan__RABIT_pancan.HiSeq.V2.gz',
    trim_ws = TRUE, n_max = my.limit )%>%
        ##rename(probe = sample) %>%
        mutate ( sample = make.unique(sample, sep = '_') )  %>%
            gather( probe, value, -sample ) %>%
                mutate(type = 'rabit') %>%
                    select( sample, probe, value, type )
my_rabit
## lots of zeros, sparse default TRUE
tablemaker(my_rabit)
my_rabit = NULL; gc()
