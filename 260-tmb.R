library(tidyverse)
source('tablemaker.R')

samples = tbl(con, "samples"); probes = tbl(con, "probes"); tcgacati = tbl(con, "tcgacati")

fmut = tcgacati %>% filter( type == 'fmut' ) %>%
    left_join( samples %>% rename( samplekey = key) ) %>%
        left_join( probes %>% rename( probekey = key ) ) %>%
            select( sample, probe, value, type ) %>% collect
fmut

tmb = fmut %>%
    group_by( sample ) %>% 
        count(sort = TRUE)  %>%
            ungroup %>% 
                rename(value = n ) %>%
                    mutate( value = log10(value + 1) ) %>%
                        mutate( probe = 'tmb', type = 'tmb' ) %>%
                            select(sample, probe, value, type) %>% collect
dim(tmb)

tablemaker(tmb, suffix = FALSE, deleteType = TRUE)
