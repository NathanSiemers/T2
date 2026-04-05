
################################################################
## position specific mutation
## 1. load dedicated table

my_mutation = read_tsv('Data/mc3.v0.2.8.PUBLIC.xena.gz',
    trim_ws = TRUE  )   #####, n_max = my.limit )
my_mutation

## make 'gene' names that add some information about mutation
my_mutation$shortgene = with( my_mutation, paste0(gene, '_', Amino_Acid_Change) )
my_mutation$shortgene = gsub( "\\*", 's', my_mutation$shortgene)
my_mutation$longgene = with( my_mutation, paste0(gene, '_', Amino_Acid_Change, '_', effect) )
my_mutation$longgene = gsub( "\\'", 'p', my_mutation$longgene)
my_mutation$longgene = gsub( "\\*", 's', my_mutation$longgene)

head(my_mutation$longgene)

unique(my_mutation$effect)

##try(dbRemoveTable(con, 'mutation'), silent = TRUE)
dbWriteTable(con, 'mutation', my_mutation, overwrite = TRUE, row.names = FALSE)

## create table of all samples with mutations called
## hopefully this is all samples exome sequenced
try(dbRemoveTable(con, 'mutationsamples'), silent = TRUE)
dbExecute(con, 'create table mutationsamples as select distinct sample from mutation')
## LOOK HERE?
dbGetQuery(con, 'select * from mutationsamples limit 10')
dim(dbGetQuery(con, 'select * from mutationsamples' ))

## 2. add abbreviated data to tcga

my_fmut = my_mutation %>%
    select( sample, probe = gene, value = longgene ) %>%
        mutate( type = 'fmut' )

my_fmut
tablemaker( my_fmut, categorical = TRUE, sparse = FALSE, r_datatype = "factor" )
my_fmut = NULL; gc()

## add a mutation tested "probe" to tcgai

samples = dbGetQuery(con, 'select * from mutationsamples')

mutationtested = data.frame(
    sample = samples$sample,
    probe = 'muttest',
    value = 1,
    type = 'muttest',
    stringsAsFactors = FALSE
    )

tablemaker( mutationtested, r_datatype = "factor" )

if(mysql){
    try(dbExecute(  con,  'drop index mutidx on mutation' ), silent = TRUE)
    try(dbExecute(  con, 'drop index mutationsamplesidx on mutationsamples' ), silent = TRUE)
    dbExecute( con, 'alter table mutation modify gene varchar(35)')
    dbExecute( con, 'alter table mutationsamples modify sample varchar(35)')
} else {
    dbExecute(  con,  'drop index if exists mutidx' )
    dbExecute(  con, 'drop index if exists mutationsamplesidx' )
}


dbExecute(  con, 'create index mutidx on mutation (gene)' )
dbExecute(  con, 'create index mutationsamplesidx on mutationsamples(sample)' )
