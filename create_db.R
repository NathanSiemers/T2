library(tidyverse)
library(sqldf)

source('tablemaker.R')

TESTING = FALSE
DESTROYOLD = TRUE

if( TESTING ) {
    my.limit = 100
    db = 'tcga.testdelete.db'
} else {
    my.limit = Inf
    db = 'tcga.db'
}    

if ( DESTROYOLD ) {
    file.remove(db)
    query = paste0('attach "', db, '" as new')
    sqldf(query)
    sqldf('select name from sqlite_master', db = db)
}


################################################################
## create core tables

## tcga numeric data with integer keys for sample and probe
sqldf('drop table if exists tcgai', db = db)
sqldf( 'create table tcgai (samplekey integer, probekey integer, value numeric, type character)', db = db )
## tcga categorical data with integer keys
sqldf('drop table if exists tcgacati', db = db)
sqldf( 'create table tcgacati (samplekey integer, probekey integer, value character, type character)', db = db )
## table of probes, often gene symbols without suffix (.mut, .cnv, etc)
sqldf( 'drop table if exists probes', db = db )
sqldf( 'create table probes (key integer primary key, probe character unique not null) ' , db = db )
## table of probe.type combinations - useful for app menus, etc.
sqldf( 'drop table if exists allprobes', db = db )
sqldf( 'create table allprobes (key integer primary key, probe character unique not null) ' , db = db )
## sample name - keytable
sqldf( 'drop table if exists samples', db = db )
sqldf( 'create table samples (key integer primary key, sample character unique not null) ' , db = db )

################################################################
## create views
## you can create the views before any tables have data
## or seemingly even before tables exist? (clinpheno)

## simple tidy tcga numeric data view
sqldf( 'drop view if exists tcgas', db = db ) 
sqldf('
create view tcgas as
select samples.sample, probes.probe, tcgai.value, tcgai.type
from tcgai, samples, probes
where tcgai.samplekey = samples.key and
tcgai.probekey = probes.key
', db = db )

################################################################
## simple tidy tcga categorical data view
sqldf( 'drop view if exists tcgacats', db = db ) 
sqldf('
create view tcgacats as
select samples.sample, probes.probe, tcgacati.value, tcgacati.type
from tcgacati, samples, probes
where tcgacati.samplekey = samples.key and
tcgacati.probekey = probes.key
', db = db )

################################################################
## main TCGA view
## join untidy (wide) clinical info
## plus tidy numeric genomic data in probe and value columns

sqldf( 'drop view if exists tcga', db = db ) 
sqldf('
create view tcga as
select clinpheno.*, probe, value, type
from tcgai, samples, probes, clinpheno
where tcgai.samplekey = samples.key 
and tcgai.probekey = probes.key
and samples.sample = clinpheno.sample
', db = db )

################################################################
## main TCGA view for categorical data
## cluster/subtype assignments, etc

sqldf( 'drop view if exists tcgacat', db = db ) 
sqldf('
create view tcgacat as
select clinpheno.*, probe, value, type
from tcgacati, samples, probes, clinpheno
where tcgacati.samplekey = samples.key 
and tcgacati.probekey = probes.key
and samples.sample = clinpheno.sample
',
      db = db )



################################################################
## read tcga data files

## rna
my_rna = read_tsv('Data/EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(probe, sep = '_' ) )%>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'rna') %>%
                        select( sample, probe, value, type )
my_rna

tablemaker(my_rna, suffix = FALSE)
my_rna = NULL; gc()

## cnv
my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.gene.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(probe, sep = '_') ) %>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'cnv') %>%
                        select( sample, probe, value, type )
my_cnv

tablemaker(my_cnv)
my_cnv = NULL; gc()


################################################################
## gene-level mutations
## note
## this treatment is non-standard
## we will remove non-mutants from table
## will need to add zeros back in R
## will keep track of list of samples with mutations measured
################################################################
my_mut = read_tsv('Data/mc3.v0.2.8.PUBLIC.nonsilentGene.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(probe, sep = '_') ) %>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'mut') %>%
                        select( sample, probe, value, type ) %>%
                            filter( value != 0 )
my_mut

tablemaker(my_mut)

my_mut = NULL; gc()

################################################################
## micro (u) RNA
################################################################

my_urna = read_tsv('Data/pancanMiRs_EBadjOnProtocolPlatformWithoutRepsWithUnCorrectMiRs_08_04_16.xena.gz', 
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(probe, sep = '_') )  %>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'urna') %>%
                        select( sample, probe, value, type )
my_urna

tablemaker(my_urna)
my_urna = NULL; gc()


################################################################
## there's a file corruption here, skipping for now
## my_pc_gene_program = read_tsv('Data/Pancan12_GenePrograms_drugTargetCanon_in_Pancan33.tsv.gz',
##     trim_ws = TRUE, n_max = my.limit ) %>%
##         gather( probe, value, -sample ) %>%
##         mutate(type = 'pc_gene_program') %>%
##             select( sample, probe, value, type )
## my_pc_gene_program
## tablemaker(my_pc_gene_program)
## my_pc_gene_program = NULL; gc()
################################################################

my_rabit = read_tsv('Data/RABIT__pancan__RABIT_pancan.HiSeq.V2.gz',
    trim_ws = TRUE, n_max = my.limit )%>%
        ##rename(probe = sample) %>%
        mutate ( sample = make.unique(sample, sep = '_') )  %>%
            gather( probe, value, -sample ) %>%
                mutate(type = 'rabit') %>%
                    select( sample, probe, value, type )
my_rabit
tablemaker(my_rabit)
my_rabit = NULL; gc()

my_hrd = read_tsv('Data/TCGA.HRD_withSampleID.txt.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = sampleID) %>%
            mutate(sample = make.unique(sample, sep = '_') ) %>%
                gather( probe, value, -sample ) %>%
                    mutate( type = 'hrd' ) %>%
                        select( sample, probe, value, type )
my_hrd

tablemaker(my_hrd)
my_hrd = NULL; gc()

my_immune_score = read_tsv('Data/TCGA_pancancer_10852whitelistsamples_68ImmuneSigs.xena.gz',
    trim_ws = TRUE, n_max = my.limit )%>%
        rename(sample = X1) %>%
            mutate(sample = make.unique(sample, sep = '_') ) %>%
                gather( probe, value, -sample ) %>%
                    mutate( type = 'immune_score' ) %>%
                        select( sample, probe, value, type )
my_immune_score

unique(my_immune_score$probe)

tablemaker(my_immune_score)
my_immune_score = NULL; gc()

my_molec_subtype = read_tsv('Data/TCGASubtype.20170308.tsv.gz',
    col_types = cols( .default=col_character() ),
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(sample = sampleID) %>%
            mutate(sample = make.unique(sample, sep = '_') ) %>%
                gather( probe, value, -sample )%>%
                    mutate( type = 'molec_subtype' ) %>%
                        select( sample, probe, value, type )
my_molec_subtype

tablemaker(my_molec_subtype, categorical = TRUE, suffix = FALSE)

my_molec_subtype = NULL; gc()

my_immune = read_tsv('Data/Subtype_Immune_Model_Based.txt.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        mutate(sample = make.unique(sample, sep = '_') ) %>%
                   gather( probe, value, -sample ) %>%
                       mutate( type = 'immune_subtype' ) %>%
                           select( sample, probe, value, type )
my_immune

tablemaker(my_immune, categorical = TRUE, suffix = FALSE)
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
    col_types = cols(
        .default = col_character(),
        age_at_initial_pathologic_diagnosis = col_double(),
        clinical_stage = col_character(),
        initial_pathologic_dx_year = col_double(),
        birth_days_to = col_double(),
        last_contact_days_to = col_double(),
        death_days_to = col_double(),
        cause_of_death = col_character(),
        new_tumor_event_dx_days_to = col_double(),
        residual_tumor = col_character(),
        OS = col_double(),
        OS.time = col_double(),
        DSS = col_double(),
        DSS.time = col_double(),
        DFI = col_double(),
        DFI.time = col_double(),
        PFI = col_double(),
        PFI.time = col_double()
        ),
    trim_ws = TRUE, n_max = my.limit )  
colnames(my_clin)

my_clin = my_clin %>% rename(Patient = '_PATIENT',
    tumtype = "cancer type abbreviation"  )

################################################################
## phenos table is small, add to clin before joining
my_pheno = read_tsv('Data/TCGA_phenotype_denseDataOnlyDownload.tsv.gz',
    trim_ws = TRUE, n_max = my.limit ) %>% rename ( cohort = "_primary_disease" )
my_pheno

dim(my_clin)
dim(my_pheno)
### oops my_pheno is bigger
which(! my_pheno$sample %in% my_clin$sample )
which(! my_clin$sample %in% my_pheno$sample )

my_clin = my_pheno %>% left_join(my_clin, b = 'sample')
dim(my_clin)
my_clin

sqldf( 'drop table if exists clin', db = db ) 
sqldf( 'create table clin as select * from my_clin', db = db )
sqldf( 'drop index if exists clintumtypeidx', db = db)
sqldf( 'create index clintumtypeidx on clin ( tumtype )', db = db)
sqldf( 'drop index if exists clincohortidx', db = db)
sqldf( 'create index clincohortidx on clin ( cohort )', db = db )
str( sqldf( 'select * from clin limit 1', db = db ) )


my_clin = NULL; gc()



################################################################
## position specific mutation
## 1. load dedicated table

my_mutation = read_tsv('Data/mc3.v0.2.8.PUBLIC.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_mutation

## make 'gene' names that add some information about mutation
my_mutation$shortgene = with( my_mutation, paste0(gene, '_', Amino_Acid_Change) )
my_mutation$shortgene = gsub( "\\*", 's', my_mutation$shortgene)
my_mutation$longgene = with( my_mutation, paste0(gene, '_', Amino_Acid_Change, '_', effect) )
my_mutation$longgene = gsub( "\\'", 'p', my_mutation$longgene)
my_mutation$longgene = gsub( "\\*", 's', my_mutation$longgene)

head(my_mutation$longgene)

unique(my_mutation$effect)

sqldf( 'drop table if exists mutation', db = db ) 
sqldf('create table mutation as select * from my_mutation', db = db)

sqldf( 'drop index if exists mutidx', db = db ) 
sqldf('create index mutidx on mutation (gene)', db = db)

## create table of all samples with mutations called
## hopefully this is all samples exome sequenced

sqldf('drop table if exists mutationsamples', db = db)
sqldf('create table mutationsamples as select distinct sample from my_mutation', db = db)
sqldf('drop index if exists mutationsamplesidx', db = db)
sqldf('create index mutationsamplesidx on mutationsamples(sample)', db = db)
sqldf('select * from mutationsamples limit 10', db = db)
dim(sqldf('select * from mutationsamples', db = db))

## 2. add abbreviated data to tcga

my_fmut = my_mutation %>%
    select( sample, probe = gene, value = longgene ) %>%
        mutate( type = 'fmut' )

my_fmut
tablemaker( my_fmut, categorical = TRUE )
my_fmut = NULL; gc()

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
## copy number segments - make a dedicated table

my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnv
sqldf( 'drop table if exists cnv', db = db ) 
sqldf('create table cnv as select * from my_cnv', db = db)
my_cnv = NULL; gc()

################################################################
## geography

my_geo = read_tsv('hugo_gencode_good_hg19_V24lift37_probemap',
    trim_ws = TRUE, n_max = my.limit )
my_geo
sqldf( 'drop table if exists geo', db = db ) 
sqldf('create table geo as select * from my_geo', db = db)
my_geo = NULL; gc()



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

sqldf( 'drop index if exists tcgaidxprobe', db = db ) 
sqldf('create index tcgaidxprobe on tcgai ( probekey, type )', db = db)
sqldf( 'drop index if exists tcgaidxsample', db = db )
sqldf('create index tcgaidxsample on tcgai( samplekey, probekey, type )', db = db)
sqldf( 'drop index if exists tcgaidxtype', db = db )
sqldf('create index tcgaidxtype on tcgai( type )', db = db)
sqldf( 'drop index if exists tcgacatidxprobe', db = db ) 
sqldf('create index tcgacatidxprobe on tcgacati ( probekey, type )', db = db)
sqldf( 'drop index if exists tcgacatidxtype', db = db ) 
sqldf('create index tcgacatidxtype on tcgacati ( type )', db = db)
sqldf( 'drop index if exists tcgacatidxsample', db = db )
sqldf('create index tcgacatidxsample on tcgacati( samplekey, probekey, type )', db = db)


################################################################
## convenience tables

## don't be stupid, you already have the probe tables from your indexing
## however, you need probes x type

## this is glacially slow
##query1 = sqldf('select distinct probe, type from tcga', db = db)

##sqldf('explain query plan select probe, type from tcga', db = db)
##query1 = sqldf('select probe, type from tcga', db = db)
## dim(query1)
## pasted_probes =  paste(query1$probe, query1$type, sep = tsep )

## rna_no_suffix = sqldf('select distinct probe from tcga where type = "rna"', db = db)

## all_probes_list = data.frame(
##     probe = c(rna_no_suffix, pasted_probes)
##     )

## sqldf('drop table if exists allprobes', db = db)

## sqldf('create table allprobes as select * from all_probes_list', db = db)



phenos  = sqldf('
select sample, probe, value  from tcgacati, probes, samples
where tcgacati.probekey = probes.key
and tcgacati.samplekey = samples.key
and tcgacati.type <> "fmut"
', db = db)

unique(phenos$probe)
unique(phenos$value)
head(phenos)

phenos %>% filter( sample == 'TCGA-Z2-AA3S-06' )

phenos = phenos %>% spread(probe, value)
unique(phenos$'_primary_disease')
tail(phenos)
which(duplicated(phenos$sample))




sqldf('drop table if exists clinpheno', db = db)
sqldf('
create table clinpheno as
select * from clin
left outer join phenos
on clin.sample = phenos.sample
', db = db)

str(sqldf('select * from clinpheno limit 5', db = db))

## clinical columns can be used as probes, need to be registered into allprobes
allprobe = data.frame(
    key = NA,
    probe = colnames(sqldf('select * from clin limit 1', db = db) )
    )
sqldf('insert or ignore into allprobes select key, probe from allprobe', db = db )



sqldf('drop index if exists clinphenoidx', db = db)
sqldf('
create index clinphenoidx on clinpheno(sample)
', db = db)



sqldf('drop table if exists types', db = db)
sqldf('create table types as select distinct type from tcgai', db = db)
sqldf('insert into types select distinct type from tcgacati', db = db)
sqldf('select * from types', db = db)


## massage the cohorts table
clintmpclean  = sqldf('select tumtype, cohort from clin', db = db) %>% drop_na %>% distinct
clintmpclean$string = with( clintmpclean, paste(cohort, '(', tumtype, ')' ) )
clintmpclean = clintmpclean %>% rename(cohort = tumtype, lcohort = cohort, cohortstring = string)
sqldf('drop table if exists cohorts', db = db)
sqldf('create table cohorts as select * from clintmpclean', db = db)
sqldf('select * from cohorts', db = db)

## not work, Subtype_Selected isn't here
##sqldf('drop table if exists subtypes', db = db)
##sqldf('create table subtypes as select distinct Subtype_Selected as subtype from clinpheno', db = db)

##phenos  = sqldf('select sample, probe, value, type from tcgacat', db = db) %>%
##    spread(probe, value)

## spread sample categorical values out into dedicated table
## that's joined with patient-level information
## "clinpheno"






################################################################
## test queries, in sql and dplyr
################################################################

if( FALSE ) {
    Sys.time()
    nothing = sqldf('select * from tcga where probe = "10357" and type = "rna"', db = db)
    Sys.time()

    sqldf('explain query plan select * from tcga where probe = "10357" and type = "rna"', db = db)

    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and probe = "10357" and type = "rna"', db = db)


    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01"', db = db)

    sqldf('explain query plan select * from tcga where sample in ( "TCGA-CG-4440-01" )', db = db)

    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and probe = "10357" ', db = db)

    sqldf('explain query plan select * from tcga where sample = "TCGA-CG-4440-01" and type = "rna"', db = db)

    sqldf('explain query plan select distinct type from tcga', db = db)


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

    ## ggplot on tidy data
    library(ggplot2)

    somestuff = tcga %>%  filter(
        ( probe == 'CD8A'  & type == 'rna')   |
            ( probe == 'CD19'  & type == 'rna')   |
                ( probe == 'CDKN2A' & type == 'cnv' ) |
                    ( probe == 'MYC' & type == 'cnv' )
        )




    sp = somestuff %>% select(sample,  probe, value) %>% data.frame  %>% spread( key = probe, value = value) 
    dim(sp)

    ggplot(aes(x = CDKN2A, y = CD8A), data = sp)  + geom_point() + geom_smooth(method = 'lm')
    ggplot(aes(x = 2 ** CDKN2A, y = CD8A), data = sp)  + geom_point() + geom_smooth(method = 'lm')

    qplot(CDKN2A, data = sp)

    ggplot(aes(x = MYC, y = CD8A), data = sp)  + geom_point() + geom_smooth(method = 'lm')

    ggplot(aes(x = 2**MYC, y = CD8A), data = sp)  + geom_point() + geom_smooth(method = 'lm')

}
