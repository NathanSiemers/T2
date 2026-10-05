## rppa

## check.names = FALSE: keep the sample barcodes as they are in the file, so that a
## sample that appears twice is seen as such (and averaged) instead of being renamed
my_rppa = read.csv('Data/TCGA-RPPA-pancan-clean.xena.gz', sep = '\t', check.names = FALSE) %>%
    average_duplicate_columns('rppa')
my_rppa[1:20,1:5]


my_rppa = my_rppa %>%
    rename(probe = SampleID) %>%
    ##mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
    ##gather( sample, value, -probe ) %>% head
    gather( sample, value, -probe ) %>%
    mutate(type = 'rppa') %>%
    mutate( sample = gsub('\\.' , '-', sample) )   %>%
                select( sample, probe, value, type )
           ## my_rppa = my_rppa %>%
##     rename(sample = SampleID) %>%
##         ##mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
##         ##gather( sample, value, -probe ) %>% head
##         gather( probe, value, -sample ) %>%
##                 mutate(type = 'rppa') %>%
##                     select( sample, probe, value, type )

head(my_rppa)
## sanity checks
dim(my_rppa)
##my_rppa %>% filter(probe == 'CDKN2A')
##dat = my_rppa; suffix = TRUE; categorical = FALSE; tsep = '.'; deleteType = FALSE; connection = con

tablemaker(my_rppa, sparse = FALSE)

my_rppa = NULL; gc()

