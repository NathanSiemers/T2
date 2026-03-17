
################################################################
## gene-level mutations
## note
## this treatment is non-standard
## we will remove non-mutants from table
## will need to add zeros back in R
## will keep track of list of samples with mutations measured
################################################################
my_mut = read_tsv('Data/mc3.v0.2.8.PUBLIC.nonsilentGene.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'mut') %>%
                        select( sample, probe, value, type ) 
##        %>% filter( value != 0 )
my_mut

tablemaker(my_mut, sparse = TRUE)

my_mut = NULL; gc()
