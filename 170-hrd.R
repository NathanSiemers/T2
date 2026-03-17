
my_hrd = read_tsv('Data/TCGA.HRD_withSampleID.txt.gz',
                  trim_ws = TRUE, n_max = my.limit ) %>%
    rename(probe = sampleID) %>%
    gather( sample, value, -probe) %>%
    mutate( type = 'hrd' ) %>%
    select( sample, probe, value, type)

my_hrd

length(unique(my_hrd$sample))

## decent number of zeroes sparse = TRUE (default)
tablemaker(my_hrd)

my_hrd = NULL; gc()


## old


## my_hrd = read_tsv('Data/TCGA.HRD_withSampleID.txt.gz',
##     trim_ws = TRUE, n_max = my.limit ) %>%
##         rename(sample = sampleID) %>%
##             mutate(sample = make.unique(sample, sep = '_') ) %>%
##                 gather( probe, value, -sample ) %>%
##                     mutate( type = 'hrd' ) %>%
##                        select( sample, probe, value, type )
