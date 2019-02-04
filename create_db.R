library(tidyverse)
library(sqldf)

## set finite my.limit for testing, set to Inf for production
my.limit = Inf


db = 'tcga.db'
query = paste0('attach "', db, '" as new')
sqldf(query)


################################################################
## create core tables

try(sqldf('drop table if exists tcgai', db = db))
sqldf( 'create table tcgai (sample integer, probe integer, value numeric, type character)', db = db )
try(sqldf('drop table if exists tcgacati', db = db))
sqldf( 'create table tcgacati (sample integer, probe integer, value character, type character)', db = db )
try(sqldf( 'drop table if exists probes', db = db ))
sqldf( 'create table probes (key integer primary key, probe character unique not null) ' , db = db )
try(sqldf( 'drop table if exists samples', db = db ))
sqldf( 'create table samples (key integer primary key, sample character unique not null) ' , db = db )

################################################################
## create views
## it's ok that everything is empty right now...

try( sqldf( 'drop view if exists tcga', db = db ) )
sqldf('
create view tcga as
select samples.sample, probes.probe, tcgai.value, tcgai.type
from tcgai, samples, probes
where tcgai.sample = samples.key and
tcgai.probe = probes.key
', db = db )
try( sqldf( 'drop view if exists tcgacat', db = db ) )
sqldf('
create view tcgacat as
select samples.sample, probes.probe, tcgacati.value, tcgacati.type
from tcgacati, samples, probes
where tcgacati.sample = samples.key and
tcgacati.probe = probes.key
', db = db )


tablemaker = function( data, db = 'tcga.db', suffix = FALSE, type = 'numeric' ) {
    ## input: a tidy of sample, probe, value, type
    ## convert sample and probe into integer keys while updating:
    ##      sampleykeys and probes tables
    ## insert tidy data with integer keys into main table ('tcga')
    ##
    ## not sure at this point if adding '.cnv', '.mut' suffixes to probes is good or bad
    ## guessing 'bad'
    ##
    print(db)
    if( type == 'numeric' ) {
        dest_table = 'tcgai'
    } else {
        dest_table = 'tcgacati'
    }
    ## add any new sample keys to samples
    usample = data %>% select( sample ) %>%
        distinct %>%
            mutate( key = NA ) %>%
                select( key, sample )
    print( head( usample ) )
    sqldf('insert or ignore into samples select key, sample from usample', db = db )
    print( sqldf( 'select * from samples limit 5', db = db ) )
    ## add any new probe keys to probes
    uprobe = data %>% distinct(probe)
    if ( suffix ) {
        uprobe = uprobe %>%
            mutate( newprobe = paste( probe, type, sep = '.' ) ) %>%
                mutate( key = NA, probe = newprobe ) %>%
                    select( key, probe )
    } else {
        uprobe = uprobe %>%
            mutate( key = NA ) %>%
                select( key, probe )
    }
    print( head( uprobe ) )
    sqldf('insert or ignore into probes select key, probe from uprobe', db = db )
    print( sqldf( 'select * from probes limit 5', db = db ) )
    ## Do the joins in the database
    sql_string =  paste(
        'insert into',
        dest_table, '
select samples.key as sample, probes.key as probe, data.value, data.type
from data
inner join samples on samples.sample = data.sample
inner join probes on probes.probe = data.probe
' )
    print(sql_string)
    sqldf(sql_string, db = db)
}


my_rna = read_tsv('Data/EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'rna') %>%
                    select( sample, probe, value, type )
my_rna

tablemaker(my_rna)
my_rna = NULL; gc()


my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.gene.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'cnv') %>%
                    select( sample, probe, value, type )
my_cnv

tablemaker(my_cnv)
my_cnv = NULL; gc()



my_mut = read_tsv('Data/mc3.v0.2.8.PUBLIC.nonsilentGene.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'mut') %>%
                    select( sample, probe, value, type )
my_mut

tablemaker(my_mut)
my_mut = NULL; gc()

my_urna = read_tsv('Data/pancanMiRs_EBadjOnProtocolPlatformWithoutRepsWithUnCorrectMiRs_08_04_16.xena.gz', 
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'urna') %>%
                    select( sample, probe, value, type )
my_urna

tablemaker(my_urna)
my_urna = NULL; gc()


my_pc_gene_program = read_tsv('Data/Pancan12_GenePrograms_drugTargetCanon_in_Pancan33.tsv.gz',
    trim_ws = TRUE, n_max = my.limit ) %>% gather( probe, value, -sample ) %>%
        mutate(type = 'pc_gene_program') %>%
            select( sample, probe, value, type )
my_pc_gene_program

tablemaker(my_pc_gene_program)
my_pc_gene_program = NULL; gc()

my_hrd = read_tsv('Data/TCGA.HRD_withSampleID.txt.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = sampleID) %>%
            gather( probe, value, -sample ) %>%
                mutate( type = 'hrd' ) %>%
                    select( sample, probe, value, type )
my_hrd

tablemaker(my_hrd)
my_hrd = NULL; gc()

my_immune_score = read_tsv('Data/TCGA_pancancer_10852whitelistsamples_68ImmuneSigs.xena.gz',
    trim_ws = TRUE, n_max = my.limit )%>%
        rename(sample = X1) %>%
            gather( probe, value, -sample ) %>%
                mutate( type = 'immune_score' ) %>%
                    select( sample, probe, value, type )
my_immune_score

tablemaker(my_immune_score)
my_hrd = NULL; gc()



################################################################
## tidy categorical variables


my_pheno = read_tsv('Data/TCGA_phenotype_denseDataOnlyDownload.tsv.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        gather( probe, value, -sample ) %>%
            mutate( type = 'pheno' ) %>%
                select( sample, probe, value, type )
my_pheno

tablemaker(my_pheno, type = 'cat')
my_pheno = NULL; gc()

my_molec_subtype = read_tsv('Data/TCGASubtype.20170308.tsv.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = sampleID) %>%
            gather( probe, value, -sample ) %>%
                mutate( type = 'molec_subtype' ) %>%
                    select( sample, probe, value, type )
my_molec_subtype

tablemaker(my_molec_subtype, type = 'cat')
my_molec_subtype = NULL; gc()

my_immune = read_tsv('Data/Subtype_Immune_Model_Based.txt.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        gather( probe, value, -sample ) %>%
            mutate( type = 'immune_subtype' ) %>%
                select( sample, probe, value, type )
my_immune

tablemaker(my_immune, type = 'cat')
my_immune = NULL; gc()


################################################################
## we really should not put clin in tidy format
## it gets it's own table for now
## or, because of a quirk in sqlite, we can decide to do both later


## my_clin = read_tsv('Data/CuratedClinicalSurvival_SupplementalTable_S1_20171025_xena_sp.gz',
##     trim_ws = TRUE, n_max = my.limit ) %>%
##         gather( probe, value, -sample ) %>%
##             mutate( type = 'clinical' ) %>%
##                 select( sample, probe, value, type )
## my_clin

##my_clin = read_tsv('Data/CuratedClinicalSurvival_SupplementalTable_S1_20171025_xena_sp.gz',

my_clin = read_tsv('Data/Survival_SupplementalTable_S1_20171025_xena_sp.gz',
    trim_ws = TRUE, n_max = my.limit ) 
my_clin

try( sqldf( 'drop table if exists clin', db = db ) )
sqldf( 'create table clin as select * from my_clin', db = db )
str( sqldf( 'select * from clin limit 1', db = db ) )
my_clin = NULL; gc()



################################################################
## position specific mutation
## 1. load dedicated table

my_mutation = read_tsv('Data/mc3.v0.2.8.PUBLIC.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_mutation
try( sqldf( 'drop table if exists mutation', db = db ) )
sqldf('create table mutation as select * from my_mutation', db = db)

try( sqldf( 'drop index if exists mutidx', db = db ) )
sqldf('create index mutidx on mutation (gene)', db = db)

## 2. add abbreviated data to tcga

my_mutation$gene = with( my_mutation, paste0(gene, '.', Amino_Acid_Change) )

my_fmut = my_mutation %>%
    select( sample, probe = gene ) %>%
        mutate( value = 1 ) %>%
            mutate( type = 'fmut' )
my_fmut

tablemaker( my_fmut )
my_fmut = NULL; my_mutation = NULL ; gc()

################################################################
## copy number segments - make a dedicated table

my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnv
try( sqldf( 'drop table if exists cnv', db = db ) )
sqldf('create table cnv as select * from my_cnv', db = db)
my_cnv = NULL; gc()

################################################################
## Q.? what are we going to do with ginormous methylaton data?
## A. We are going to skip it for now.


## load the probe mappings
## probes can be duplicated if mapping to more than one gene

## my_meprobe = read_tsv('Data/illuminaMethyl450_hg19_GPL16304_TCGAlegacy',
##     trim_ws = TRUE, n_max = my.limit ) %>%
##         separate_rows( gene, sep = ',' )
## my_meprobe

## sqldf('create table meprobe as select * from my_meprobe', db = db)
## sqldf('create index meprobeidx on meprobe(gene)', db = db)
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
## sqldf('insert into methyl select * from my_methyl', db = db)
## my_methyl = NULL; gc()
## it's 4:20 PM on a Friday and I'm writing perl
##try(sqldf('drop table if exists methyl', db = db) )
## read.csv.sql( "",
##              sql = 'create table methyl as select * from file',
##              filter = 'cat jhu-usc.edu_PANCAN_HumanMethylation450.betaValue_whitelisted.tsv.synapse_download_5096262.xena.gz | gunzip | perl tidy.pl',
##              db = db
##              )

## read.csv.sql("methyl.csv.gz",
##              sql = 'create table methyl as select * from file',
##              db = db
##              )




################################################################
## indices

try( sqldf( 'drop index if exists tcgaidxprobe', db = db ) )
sqldf('create index tcgaidxprobe on tcgai ( probe, type )', db = db)

try(sqldf( 'drop index if exists tcgaidxsample', db = db ))
sqldf('create index tcgaidxsample on tcgai( sample, probe, type )', db = db)

try( sqldf( 'drop index if exists tcgacatidxprobe', db = db ) )
sqldf('create index tcgacatidxprobe on tcgacati ( probe, type )', db = db)

try(sqldf( 'drop index if exists tcgacatidxsample', db = db ))
sqldf('create index tcgacatidxsample on tcgacati( sample, probe, type )', db = db)



################################################################
## convenience tables


## spread sample categorical values out into dedicated table
## that's joined with patient-level information
## "clinpheno"

phenos  = sqldf('select sample, probe, value from tcgacat', db = db) %>%
    spread(probe, value)

sqldf('drop table if exists clinpheno', db = db)

sqldf('
create table clinpheno as
select * from phenos
left outer join clin
on clin.sample = phenos.sample
', db = db)







################################################################
## test queries


Sys.time()
nothing = sqldf('select * from tcga where probe = "10357" and type = "rna"', db = db)
Sys.time()

sqldf('explain query plan select * from tcga where probe = "10357" and type = "rna"', db = db)

sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and probe = "10357" and type = "rna"', db = db)


sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01"', db = db)

sqldf('explain query plan select * from tcga where sample in ( "TCGA-CG-4440-01" )', db = db)

sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and probe = "10357" ', db = db)

sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and type = "rna"', db = db)


Sys.time()
nothing = sqldf('select * from tcga where probe = "CDKN2A" and type = "cnv"', db = db)
Sys.time()
nothing = sqldf('select * from tcga where probe = "CDKN2A"', db = db)


sqldf('explain query plan select * from tcga where probe = "FOXP3"', db = db)
Sys.time()
nothing = sqldf('select * from tcga where probe = "FOXP3"', db = db)
Sys.time()

sqldf('explain query plan select * from tcga where probe in ( "FOXP3", "CCR8", "CD8A") ', db = db)

Sys.time()
nothing = sqldf('select * from tcga where probe in ( "FOXP3", "CCR8", "CD8A") ', db = db)
Sys.time()


Sys.time()
nothing = sqldf('select * from tcga where probe in ( "ABCA1", "CD8B", "CD19") ', db = db)
Sys.time()

################################################################
## dplyr versions of queries

con <- DBI::dbConnect(RSQLite::SQLite(), dbname = db, flags = SQLITE_RO )
tcga = tbl(con, 'tcga') 

nothing = tcga %>%
    filter( ( probe %in% c('CDKN2A', 'MTAP', 'FOXP3', 'ABCA1', 'KIR2DL1') & type == 'rna')   | 
               ( probe %in% c('CDKN2A', 'MTAP', 'FOXP3', 'ABCA1', 'KIR2DL1') & type == 'cnv')   ) %>%
                   data.frame

