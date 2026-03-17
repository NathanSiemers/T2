





################################################################
## experimental - numeric VAF 'fmutn'

## my_fmutvaf = my_mutation %>%
##     select( sample, probe = shortgene, value = DNA_VAF ) %>%
##             mutate( type = 'fmutvaf' )
## my_fmutvaf

## tablemaker( my_fmutvaf )
## my_fmutvaf = NULL; my_mutation = NULL ; gc()


## (see above)
## if we are going to spend disk space to make queries easy
## I need to add 0 in samples tested and without mutation.
## hmmm.  that's a lot of 0's for little return
## should this be in the database or built into a gitr query?
## should we also do this for gene-level mutation?
## if we expand 'wt' in the gitr query we can save some space in db
## I think we should make the tables sparse and note which were tested and wt.
## This could eventually also work for lossy RNA data :)



################################################################
## Q.? what are we going to do with ginormous methylaton data?
## A. We are going to skip it for now.


## load the probe mappings
## probes can be duplicated if mapping to more than one gene

## my_meprobe = read_tsv('Data/illuminaMethyl450_hg19_GPL16304_TCGAlegacy',
##     trim_ws = TRUE, n_max = my.limit ) %>%
##         separate_rows( gene, sep = ',' )
## my_meprobe

## sqldf('create table meprobe as select * from my_meprobe', connection =  con)
## sqldf('create index meprobeidx on meprobe(gene)', connection =  con)
## my_meprobe = NULL; gc()

## load tidy huge methylation data
## read_tsv has a C stack overflow
## abandon - it is too large

## my_methyl = read.csv('jhu-usc.edu_PANCAN_HumanMethylation450.betaValue_whitelisted.tsv.synapse_download_5096262.xena.gz', sep = '\t')
## %>%
##             gather( probe, value, -sample ) %>%
##                 mutate( type = 'methylical' ) %>%
##                     select( sample, probe, value, type )
## my_methyl
## sqldf('insert into methyl select * from my_methyl', connection =  con)
## my_methyl = NULL; gc()
## it's 4:20 PM on a Friday and I'm writing perl
##try(sqldf('drop table if exists methyl', connection =  con) )
## read.csv.sql( "",
##              sql = 'create table methyl as select * from file',
##              filter = 'cat jhu-usc.edu_PANCAN_HumanMethylation450.betaValue_whitelisted.tsv.synapse_download_5096262.xena.gz | gunzip | perl tidy.pl',
##              connection =  con
##              )

## read.csv.sql("methyl.csv.gz",
##              sql = 'create table methyl as select * from file',
##              connection =  con
##              )
################################################################
## convenience tables

## don't be stupid, you already have the probe tables from your indexing
## however, you need probes x type

## this is glacially slow
##query1 = sqldf('select distinct probe, type from tcga', connection =  con)

##sqldf('explain query plan select probe, type from tcga', connection =  con)
##query1 = sqldf('select probe, type from tcga', connection =  con)
## dim(query1)
## pasted_probes =  paste(query1$probe, query1$type, sep = tsep )

## rna_no_suffix = sqldf('select distinct probe from tcga where type = "rna"', connection =  con)

## all_probes_list = data.frame(
##     probe = c(rna_no_suffix, pasted_probes)
##     )

## sqldf('drop table if exists allprobes', connection =  con)

## sqldf('create table allprobes as select * from all_probes_list', connection =  con)

################################################################
## you need to create some indices here before the phenos query
## then some after clinpheno is created

if ( mysql ) {
    try(dbExecute(  con,  'drop index tcgaidxprobe on tcgai' ) , silent = TRUE)
    try(dbExecute(  con,  'drop index tcgaidxsample on tcgai' ), silent = TRUE)
    try(dbExecute(  con,  'drop index tcgaidxtype on tcgai' ), silent = TRUE)
    try(dbExecute(  con,  'drop index tcgacatidxprobe on tcgacati' ), silent = TRUE)
    try(dbExecute(  con,  'drop index tcgacatidxsample on tcgai' ), silent = TRUE)
    try(dbExecute(  con,  'drop index tcgacatidxtype on tcgai' ), silent = TRUE)
} else {
    dbExecute(  con,  'drop index if exists tcgaidxprobe' ) 
    dbExecute(  con,  'drop index if exists tcgaidxtype' ) 
    dbExecute(  con,  'drop index if exists tcgaidxsample' )
    dbExecute(  con,  'drop index if exists tcgacatidxprobe' ) 
    dbExecute(  con,  'drop index if exists tcgacatidxtype' ) 
    dbExecute(  con,  'drop index if exists tcgacatidxsample' )
    dbExecute(  con,  'drop index if exists mutidx' )
    dbExecute(  con, 'drop index if exists mutationsamplesidx' )
}

##    ## we also need to change text attributes of some tables


##dbGetQuery(con, 'select distinct value from tcgacati')

################################################################
## more indexing
## try(dbExecute(  con, 'drop index tcgaidxprobe on tcgai'), silent=TRUE )
## dbExecute(  con, 'create index tcgaidxprobe on tcgai ( probekey, type )')


if(mysql) {
    try(dbExecute(  con, 'drop index tcgacatidx_pt on tcgacati'), silent = TRUE)
    dbExecute(  con, 'create index tcgacatidx_pt on tcgacati( probekey, type ) using hash')
    try(dbExecute(  con, 'drop index tcgaidx_pt on tcgai'), silent = TRUE)
    dbExecute(  con, 'create index tcgaidx_pt on tcgai( probekey, type ) using hash')
    try(dbExecute(  con, 'drop index tcgaidx_t on tcgai'), silent = TRUE)
    dbExecute(  con, 'create index tcgaidx_t on tcgai( type ) using hash')
    try(dbExecute(  con, 'drop index tcgacatidx_t on tcgacati'), silent = TRUE)
    dbExecute(  con, 'create index tcgacatidx_t on tcgacati( type ) using hash')
} else {
    try(dbExecute(  con, 'drop index tcgaidx_pt'), silent = TRUE)
    dbExecute(  con, 'create index tcgaidx_pt on tcgai ( probekey, type )')
    try(dbExecute(  con, 'drop index tcgacatidx_pt'), silent = TRUE)
    dbExecute(  con, 'create index tcgacatidx_pt on tcgacati ( probekey, type )')
    try(dbExecute(  con, 'drop index tcgaidx_t'), silent = TRUE)
    dbExecute(  con, 'create index tcgaidx_t on tcgai ( type )')
    try(dbExecute(  con, 'drop index tcgacatidx_t'), silent = TRUE)
    dbExecute(  con, 'create index tcgacatidx_t on tcgacati ( type )')
}


##phenos  = sqldf('select sample, probe, value, type from tcgacat', connection =  con) %>%
##    spread(probe, value)

## spread sample categorical values out into dedicated table
## that's joined with patient-level information
## "clinpheno"






################################################################
## test queries, in sql and dplyr
################################################################

if( FALSE ) {
    Sys.time()
    nothing = sqldf('select * from tcga where probe = "10357" and type = "rna"', connection =  con)
    Sys.time()

    sqldf('explain query plan select * from tcga where probe = "10357" and type = "rna"', connection =  con)

    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and probe = "10357" and type = "rna"', connection =  con)


    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01"', connection =  con)

    sqldf('explain query plan select * from tcga where sample in ( "TCGA-CG-4440-01" )', connection =  con)

    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and probe = "10357" ', connection =  con)

    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and type = "rna"', connection =  con)

    sqldf('explain query plan select distinct type from tcga', connection =  con)


    Sys.time()
    nothing = sqldf('select * from tcga where probe = "CDKN2A" and type = "cnv"', connection =  con)
    Sys.time()
    nothing = sqldf('select * from tcga where probe = "CDKN2A"', connection =  con)


    sqldf('explain query plan select * from tcga where probe = "FOXP3"', connection =  con)
    Sys.time()
    nothing = sqldf('select * from tcga where probe = "FOXP3"', connection =  con)
    Sys.time()

    sqldf('explain query plan select * from tcga where probe in ( "FOXP3", "CCR8", "CD8A") ', connection =  con)

    Sys.time()
    nothing = sqldf('select * from tcga where probe in ( "FOXP3", "CCR8", "CD8A") ', connection =  con)
    Sys.time()


    Sys.time()
    nothing = sqldf('select * from tcga where probe in ( "ABCA1", "CD8B", "CD19") ', connection =  con)
    Sys.time()

################################################################
    ## dplyr versions of queries

    ##con <- DBI::dbConnect(RSQLite::SQLite(), dbname = db, flags = SQLITE_RO )
    tcga = tbl(con, 'tcga') 
    tcgai = tbl(con, 'tcgacati') 

    nothing = tcga %>%
        filter( ( probe %in% c('CDKN2A', 'MTAP', 'FOXP3', 'ABCA1', 'KIR2DL1') & type == 'rna')   | 
                   ( probe %in% c('CDKN2A', 'MTAP', 'FOXP3', 'ABCA1', 'KIR2DL1') & type == 'cnv')   ) %>%
                       data.frame



    tcga %>%
        filter(  probe %in% probelist & type == mytype)  %>%
            data.frame %>% spread( probe, value )




    list1 = c('FOXP3', 'CCR8', 'CD8A', 'CCR4')

    str(gitr(list1))
}
