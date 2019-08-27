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
mutationsamples = tbl(con, "mutationsamples")  %>% pull(sample)  ## clinical/phenotype table
allcohorts = unique(clinpheno %>% pull(cohort))

## numeric tcga data in tidy format
tcgas

tcgas %>% filter(probe == 'KRAS')

tcgas %>% filter(probe == 'KRAS.mut')
## important - wt not stored in database.
## you can get all samples tested for mutation from mutationsamples
## samples in mutationsamples without a mutation are correctly inferred as wild type.
head(mutationsamples)


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


################################################################
## for Jun


library(data.table)

prostatedata = clinpheno %>% filter(cohort == "prostate adenocarcinoma") 
prostatesample = prostatedata %>% pull( sample )

## get all prostate mutants
## infer wt

d = tcgas %>%
    filter( type == "mut" ) %>%
        filter( sample %in% prostatesample) %>%
            ## only need the line below for mutation
            filter( sample %in% mutationsamples) %>%
                select( -type ) %>%
                    collect


## it is unfortunate you cannot cast nor spread in sql
## only need fill = 0 for mutations
d = dcast( setDT(d), sample ~ probe, value.var = "value", fill = 0)
d[1:5,1:5]
## join to clinpheno
d = prostatedata %>% collect %>% left_join( d )


################################################################
## get categorical data from tcgacats

## what are the types of categorical information?

tcgacats %>% pull(type) %>% unique

tcgacats %>% filter( type == 'fmut' ) 

