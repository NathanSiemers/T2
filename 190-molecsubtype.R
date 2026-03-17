
my_molec_subtype = read_tsv('Data/TCGASubtype.20170308.tsv.gz',
    col_types = cols( .default=col_character() ),
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = sampleID) %>%
            mutate(sample = make.unique(sample, sep = '_') ) %>%
                gather( probe, value, -sample )%>%
                    mutate( type = 'molec_subtype' ) %>%
                        select( sample, probe, value, type )
my_molec_subtype
length(which(is.na(my_molec_subtype$value)))
unique(my_molec_subtype$probe)
unique(my_molec_subtype$value)

tablemaker(my_molec_subtype, categorical = TRUE, sparse = FALSE)

dbGetQuery(con, 'select distinct value from tcgacati')

my_molec_subtype = NULL; gc()
