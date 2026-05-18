
my_rabit = read_tsv('Data/RABIT__pancan__RABIT_pancan.HiSeq.V2.gz',
    trim_ws = TRUE, n_max = my.limit )%>%
        ##rename(probe = sample) %>%
        mutate ( sample = make.unique(sample, sep = '_') )  %>%
            gather( probe, value, -sample ) %>%
                mutate(type = 'rabit') %>%
                    select( sample, probe, value, type )
my_rabit

if(FALSE){
  rabit_test = read_tsv('Data/RABIT__pancan__RABIT_pancan.HiSeq.V2.gz',
                        trim_ws = TRUE, n_max = my.limit )
  rabit_test
  arid = my_rabit[my_rabit$probe == "ARID3A", ]
  dim(arid)
  head(arid, 100)
}

## sparse=TRUE: zeros omitted from tcgai, backfilled by view
## real NAs (309K) preserved in tcgai by tablemaker
tablemaker(my_rabit)
my_rabit = NULL; gc()
