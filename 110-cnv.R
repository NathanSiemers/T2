
## cnv
my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.gene.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnv
my_cnv = my_cnv %>%
    rename(probe = sample) %>%
        mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'cnv') %>%
                    select( sample, probe, value, type )
my_cnv
## sanity checks
dim(my_cnv)
my_cnv %>% filter(probe == 'CDKN2A')
dat = my_cnv; suffix = TRUE; categorical = FALSE; tsep = '.'; deleteType = FALSE; connection = con
tablemaker(my_cnv)

my_cnv = NULL; gc()

