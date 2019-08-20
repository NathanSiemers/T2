library(tidyverse)
library(DBI)
## this is the magic database connection string
## read only access
## no problems with sharing this with others
con = RMySQL::dbConnect (
    drv       = RMySQL::MySQL(),
    dbname    = "pancan2018",
    host      = "pancan2018.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
    port      = 3306,
    username  = "reader",
    password  = "Readeruser19"  )
## load these convenient table bindings:
tcga = tbl(con, "tcga")  ## genomic + clinical columns
tcgas = tbl(con, "tcgas")  ## simple sample/probe/value/type view
tcgacats = tbl(con, "tcgacats")  ## simple sample/probe/value/type view
clinpheno = tbl(con, "clinpheno")  ## clinical/phenotype table

## summary breakdown of assigned subtype
clinpheno %>% select( Subtype_Selected ) %>%
    data.frame %>% table %>% as_tibble

## summary breakdown of assigned cohort
clinpheno %>% select( cohort ) %>%
    data.frame %>% table  %>% as_tibble %>% data.frame

## get all tmb data for breast cancer
## easy, as it is only one 'probe'
tmb = tcga %>%
    filter( type == "tmb" ) %>%
        filter( cohort == 'breast invasive carcinoma' ) %>%
            collect
saveRDS(tmb, file = 'tmb.rds')

################################################################
## do you want an entire set of genomics data?
## you'll need to be patient and have RAM
## a good network to east coast amazon also helps 
## data.table library is recommended for spread/cast
library(data.table)

breastdata = clinpheno %>% filter(cohort == 'breast invasive carcinoma') 
breastsample = breastdata %>% pull( sample )

d = tcgas %>%
    filter( type == "rna" ) %>%
        filter( sample %in% breastsample) %>%
            select( -type ) %>%
                collect

## it is unfortunate you cannot cast nor spread in sql 
d = dcast( setDT(d), sample ~ probe, value.var = "value")
## join to clinpheno
d = breastdata %>% collect %>% left_join( d )

saveRDS(d, file = 'tcga_breast_rna.rds')



