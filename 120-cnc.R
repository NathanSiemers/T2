
## cnc : thresholded gistic copy number
## note: sample is Sample on header of this data set
my_cnc = read_tsv('Data/TCGA.PANCAN.sampleMap__Gistic2_CopyNumber_Gistic2_all_thresholded.by_genes.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnc
my_cnc = my_cnc %>%
    rename(probe = Sample) %>%
        mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'cnc') %>%
                    select( sample, probe, value, type )
my_cnc
tablemaker(my_cnc)
my_cnc = NULL; gc()

