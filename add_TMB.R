library(sqldf)
library(tidyverse)

source('tablemaker.R')
db = 'tcga.db'

fmut = sqldf('select * from tcgacats where type = "fmut"', db = db)

tmb = fmut %>%
    group_by( sample ) %>% 
        count(sort = TRUE)  %>%
            ungroup %>% 
                rename(value = n ) %>%
                    mutate( value = log10(value + 1) ) %>%
                        mutate( probe = 'tmb', type = 'tmb' ) %>%
                            select(sample, probe, value, type)

tablemaker(tmb, suffix = FALSE, deleteType = TRUE)










