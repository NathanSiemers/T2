################################################################
## read tcga data files

## rna
my_rna = read_tsv('Data/EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(as.character(probe), sep = '_' ) )%>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'rna') %>%
                        select( sample, probe, value, type )
my_rna

tablemaker(my_rna, suffix = FALSE)

my_rna = NULL; gc()
