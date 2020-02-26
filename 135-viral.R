
my_viral = read_tsv('https://api.gdc.cancer.gov/data/a55229b3-da03-49fc-a310-9b1bf16b8512',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = SampleBarcode) %>%
            mutate( sample = gsub('[A-Z]$', '', sample ) ) %>%
                mutate(sample = make.unique(sample, sep = '_') ) %>%
                    select( -AliquotBarcode, -ParticipantBarcode, -Study, -SampleTypeLetterCode ) %>%
                gather( probe, value, -sample ) %>%
                    mutate( type = 'viral' ) %>%
                        mutate( value = log2( value + 1 ) ) %>%
                        select( sample, probe, value, type ) 

my_viral

tablemaker(my_viral)

my_viral = NULL; gc()
