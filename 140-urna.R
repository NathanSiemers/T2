
################################################################
## micro (u) RNA
################################################################

my_urna = read_tsv('Data/pancanMiRs_EBadjOnProtocolPlatformWithoutRepsWithUnCorrectMiRs_08_04_16.xena.gz', 
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(as.character(probe), sep = '_') )  %>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'urna') %>%
                        select( sample, probe, value, type )
my_urna

## not centered at zero - sparse = FALSE
tablemaker(my_urna, sparse = FALSE)
my_urna = NULL; gc()

