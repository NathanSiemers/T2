
my_immune_score = read_tsv('Data/TCGA_pancancer_10852whitelistsamples_68ImmuneSigs.xena.gz',
    trim_ws = TRUE, n_max = my.limit )%>%
        rename(probe = ...1 ) %>%
            #mutate(sample = make.unique(sample, sep = '_') ) %>%
                gather( sample, value, -probe ) %>%
                    mutate( type = 'immune_score' ) %>%
                        select( sample, probe, value, type )
my_immune_score

unique(my_immune_score$probe)

## data highly continuous - sparse off
tablemaker(my_immune_score, sparse = FALSE)
my_immune_score = NULL; gc()
