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

## updated subtype information in clinpheno, I believe also in tcgacats but clinpheno is easier

grep('ubtype', colnames(clinpheno), value = TRUE)


## summary breakdown of assigned subtype
## 'Subtype_Selected' is the category the individual tumor teams preferred btw.

clinpheno %>% select( Subtype_Selected ) %>%
    data.frame %>% table %>% as_tibble

## summary breakdown of assigned cohort
clinpheno %>% select( cohort ) %>%
    data.frame %>% table  %>% as_tibble %>% data.frame

## get all estimate scores in tidy format
## will need to spread/cast
tmb = tcgas %>%
    filter( type == "estimate" ) %>%
        collect

tmb

saveRDS(tmb, file = 'estimate.rds')

