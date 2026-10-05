################################################################
## read tcga data files

## rna
my_rna = read_tsv('Data/EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz',
    trim_ws = TRUE, n_max = my.limit, name_repair = 'minimal' ) %>%
    average_duplicate_columns('rna') %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(as.character(probe), sep = '_' ) )%>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'rna') %>%
                        select( sample, probe, value, type )
my_rna


## NA in the EB++ matrix comes in blocks: one gene x a whole batch of samples
## (e.g. the six IFNA genes in nearly all of STAD, OV, ESCA and LAML and part of
## UCEC, COAD, READ; CA9 in all of LAML), where the gene had no usable signal for
## the batch adjustment. These are low/absent-signal genes, so they are treated
## as NOT EXPRESSED: the rows are dropped here, every sample stays `tested` for
## rna through its other genes, and the sparse model then returns 0 for them
## (about 1.75% of the matrix). To keep them as NA instead, delete the line
## below: tablemaker() stores NA rows as NULL and the views return them as NA.
cat(sprintf("rna: %d NA cells (%.2f%% of the matrix) are treated as not expressed (0)\n",
            sum(is.na(my_rna$value)), 100 * mean(is.na(my_rna$value))))
dim(my_rna)
my_rna = my_rna[!is.na(my_rna$value), ]
dim(my_rna)


tablemaker(my_rna, suffix = FALSE)

my_rna = NULL; gc()
