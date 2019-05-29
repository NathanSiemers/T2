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
## if you have a local sqlite database you can use this instead
if(FALSE){
    con = RSQLite::dbConnect(RSQLite::SQLite(), dbname = 'tcga.db', flags = RSQLite::SQLITE_RO)
}
################################################################
## load these convenient table bindings:
## you are connecting a relational database table to something that acts as a tibble/data.frame
##
## these first thre are very important and capture
## almost the entire data in the db
tcgas = tbl(con, "tcgas")  ## simple sample/probe/value/type view
tcgai = tbl(con, "tcgai")  ## simple sample/probe/value/type view
tcgacats = tbl(con, "tcgacats")  ## simple sample/probe/value/type view
clinpheno = tbl(con, "clinpheno")  ## clinical/phenotype table
## below are less necesary, more convenience
## tcga = numerical genomic + clinical
tcga = tbl(con, "tcga")  ## genomic + clinical columns
## sample list table
samples = tbl(con, "samples")
## probe list table
probes = tbl(con, "probes")
## vector of all probes
allprobes = probes %>% pull(probe)
## table of samples that were tested for mutation, will need this later
mutationsamples = tbl(con, 'mutationsamples') %>% pull(sample)
## example list of probes
myprobes = c('CCR8', 'IFNG', 'TP53.mut', 'PIK3CA.mut', 'PIK3CA.fmut')

## some properties of the clinical table
enframe(colnames(clinpheno))

## summary breakdown of assigned subtype
clinpheno %>% select( Subtype_Selected ) %>%
    data.frame %>% table %>% as_tibble

## look at tcgas - the simple numeric table of sample/probe/type things
tcgas

## simple queries
tcgas %>% filter( probe == 'FOXP3' )
tcgas %>% filter( probe == 'FOXP3.cnv' )
tcgas %>% filter( probe == 'FOXP3.mut' )
tcgas %>% filter( probe %in% myprobes )

## a simple spread() to get probes in columns
tcgas %>% filter( probe %in% myprobes ) %>%
    select( -type ) %>% collect %>%
        spread(probe, value)


## "tcga" get probe PLUS CLINICAL/SAMPLE results in tidy format

tcga %>% filter( probe == 'FOXP3' )  ## note: probe/value/type as last columns
## dimensions of results
tcga %>% filter( probe == 'FOXP3' ) %>% collect %>% dim


## a function to get you numeric genomics data
## from a list of probes
## and spread tidy data out into probe columns
genomedat = function(probes) {
    tcgas %>% 
        filter( probe %in% probes ) %>%
            select( -type ) %>%
                collect  %>% spread(probe, value)
}

genomedat( myprobes )


################################################################
## there's at least one catch for mutation
## the simple queries above aren't quite sufficient
## To save space, I *don't* store wt (0)  mutations in the database.
## I *do* store a list of samples tested for mutations.
## one can add the wt calls back in
## btw:
## the lib.R file has the function gitr() that takes care
## of this and more for you.
## Here's an example set of functions though

## get all numeric probe data and impute wt in "mut"s
gdatnumeric = function(myprobes) {
    tcgas %>% 
        filter( probe %in% myprobes ) %>% collect %>%
            select( -type ) %>%
                spread(probe, value) %>%
                    mutate_at(
                        vars( ends_with(".mut") ),
                        funs( factor( case_when(
                            is.na(.) & sample %in% mutationsamples ~ 'wt',
                            !is.na(.) & . == 1 ~ 'mut',
                            ) ) ) ) }
gdatnumeric(myprobes)

## get all categorical probe information and impute wt in "fmut"s
gdatcategorical = function(myprobes) {
                    tcgacats %>% 
                        filter( probe %in% myprobes ) %>% collect %>%
                            group_by( sample, probe, type ) %>%
                                mutate( value = paste(value, collapse = ';') ) %>%
                                    ungroup %>%
                                        distinct( sample, probe, value, type ) %>%
                                            select( -type ) %>%
                                                spread( probe, value ) %>%
                                                    mutate_at(
                                                        vars( ends_with(".fmut") ),
                                                        funs( factor( case_when(
                                                            is.na(.) & sample %in% mutationsamples ~ 'wt',
                                                            !is.na(.) ~ . ) ) ) )
                }
gdatcategorical(myprobes)
    
## the two functions above can be strung together with joins
## you can add the clinpheno clinical table too...

num_and_cat = function( myprobes ) {
    gdatnumeric(myprobes) %>%
        full_join(  gdatcategorical(myprobes) )
}

num_and_cat(myprobes)


## get it all, at least for the probes you ask for
## this one lets you get only cohorts you want

alldat = function( myprobes , cohorts = NULL) {
    out = gdatnumeric(myprobes) %>%
        full_join(  gdatcategorical(myprobes) ) %>%
            left_join( clinpheno %>% collect )
    if( !is.null(cohorts) ) {
        out = out %>% filter( tumtype  %in% cohorts )
    }
    out
}

alldat(myprobes) %>% colnames

alldat(myprobes, cohorts = 'STAD') %>% collect %>% dim



################################################################
## in addition to dplyr, you can use sql just as easily

library(sqldf)
options(sqldf.connection = con)

sqldf('select * from tcgas limit 1')

sqldf('select * from tcgas where probe = "FOXP3" limit 1')

sqldf('select * from tcgacats limit 5')

sqldf('select * from tcgacats where type = "fmut" limit 5')

out = sqldf('
select value from tcgacats
where type = "molec_subtype"
and probe = "Subtype_Selected"') %>%
    table %>% as_tibble
summary(out)





################################################################
## do you want an entire set of genomics data?
## you'll need to be patient and have RAM
## a good network to east coast amazon also helps 
## data.table library is recommended for spread/cast
library(data.table)

Sys.time()
n =   100000 ## testing only, set to Inf for query to get all rna
d = tcgas %>%
    filter( type == "rna" ) %>%
        head(n) %>%
            select(sample, probe, value) %>%
                collect
## it is unfortunate you cannot cast nor spread in sql 
d = dcast( setDT(d), sample ~ probe, value.var = "value")
Sys.time()
dim(d)
d[1:3,1:3]



## for mutation, if we pull the full .mut data
## there's an easier way to impute zeroes
## this doesn't take that long
e = tcgas %>% 
    filter( type == "mut" ) %>%
            select(-type) %>%
                collect %>%
                    spread(probe, value, fill = 0)
Sys.time()
dim(e)
e[1:5,1:5]


################################################################
## simple plots
library(ggplot2)

ggplot(  aes(x = FOXP3, y = ABCA1, color = OS, size = OS.time),
       data = alldat( c("FOXP3", "ABCA1") ) )  +
           geom_point( alpha = 0.1 ) +
               geom_smooth(method = 'lm') +
                   facet_wrap( ~ tumtype )



