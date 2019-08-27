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
mutationsamples = tbl(con, "mutationsamples")  ## clinical/phenotype table

## numeric tcga data in tidy format
tcgas

tcgas %>% filter(probe == 'KRAS')

tcgas %>% filter(probe == 'KRAS.mut')
## important - wt not stored in database.
## you can get all samples tested for mutation from mutationsamples
## samples in mutationsamples without a mutation are correctly inferred as wild type.
mutationsamples


## categorical tcga data in tidy format
tcgacats

tcgacats 

## table of clinical and subtype information for samples
clinpheno



################################################################
## gitr() is you friend when you want to know about handfuls of genes
source('../gitr.R')

d = gitr( probes = c('ABCA1', 'CDKN2A.mut', 'CDKN2A.cnv') )

dim(d)
as_tibble(d)

## hey I want the non-tumor data too

d = gitr( probes = c('ABCA1', 'CDKN2A.mut', 'CDKN2A.cnv'), nonormal = FALSE )
dim(d)


################################################################
## for Celine

## get all tmb data for breast cancer
## easy, as it is only one 'probe'
tmb = tcga %>%
    filter( type == "tmb" ) %>%
        filter( cohort == 'breast invasive carcinoma' ) %>%
            collect

tmb %>% select(sample, cohort, probe, value)

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



################################################################
## for Peter Szabo
## get Estimate scores and TCGA subtype classifications

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

