library(tidyverse)
library(sqldf)
source('tablemaker.R')

if( TESTING ) {
    my.limit = TESTINGLINES
} else {
    my.limit = Inf
}    

################################################################
## create core tables

## tcga numeric data with integer keys for sample and probe
################################################################
## sequence/auto increment tables are database specific

if( mysql ) {
    print('MySQL connection')
    dbRemoveTable(con, 'tcgai')
    ## do I need try() or not?
    dbCreateTable(con, name = 'tcgai', c(
                           samplekey = 'mediumint unsigned not null',
                           probekey = 'mediumint unsigned not null',
                           value = 'float not null',
                           type = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'tcgacati'))
    dbCreateTable(con, name = 'tcgacati', c(
                           samplekey = 'mediumint unsigned not null',
                           probekey = 'mediumint unsigned not null',
                           value = 'varchar(35) not null',
                           type = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'probes'))
    dbCreateTable(con, name = 'probes', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           probe = 'varchar(35) unique not null'))
                           ##oprobe = 'varchar(35)' ))
    dbExecute(con, 'ALTER TABLE probes AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'allprobes'))
    dbCreateTable(con, name = 'allprobes', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           probe = 'varchar(35) unique not null' ) )
    dbExecute(con, 'ALTER TABLE allprobes AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'samples'))
    dbCreateTable(con, name = 'samples', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           sample = 'varchar(35) unique not null' ) )
    dbExecute(con, 'ALTER TABLE samples AUTO_INCREMENT = 1')
    dbRemoveTable(con, 'tcgaitmp')
    dbCreateTable(con, name = 'tcgaitmp', c(
                           sample = 'varchar(35)',
                           probe = 'varchar(35)',
                           value = 'float',
                           type = 'varchar(35)' ) )
    dbRemoveTable(con, 'tcgacatitmp')
    dbCreateTable(con, name = 'tcgacatitmp', c(
                           sample = 'varchar(35)',
                           probe = 'varchar(35)',
                           value = 'varchar(35) not null',
                           type = 'varchar(35)' ) )
    dbRemoveTable(con, 'probestmp')
    dbCreateTable(con, name = 'probestmp', c(
                           key = 'mediumint unsigned',
                           probe = 'varchar(35)' ))
                           ##oprobe = 'varchar(35)'))
    dbRemoveTable(con, 'allprobestmp')
    dbCreateTable(con, name = 'allprobestmp', c(
                           key = 'mediumint unsigned',
                           probe = 'varchar(35) not null' ) )
    dbRemoveTable(con, 'samplestmp')
    dbCreateTable(con, name = 'samplestmp', c(
                           key = 'mediumint unsigned not null',
                           sample = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'types'), silent = TRUE)
    dbCreateTable(con, name = 'types', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           type = 'varchar(35) unique not null') )
    dbExecute(con, 'ALTER TABLE types AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'nosuffix'), silent = TRUE)
    dbCreateTable(con, name = 'nosuffix', c(
                           type = 'varchar(35) primary key') )
} else {
    print('Non-MySQL connection')
    try(dbRemoveTable(con, 'tcgai'), silent = TRUE)
    dbCreateTable(con, name = 'tcgai', c(
                           samplekey = 'int',
                           probekey = 'int',
                           value = 'float',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'tcgacati'), silent = TRUE)
    dbCreateTable(con, name = 'tcgacati', c(
                           samplekey = 'int',
                           probekey = 'int',
                           value = 'character',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'probes'), silent = TRUE)
    dbCreateTable(con, name = 'probes', c(
                           key = 'integer primary key',
                           probe = 'character unique not null'))
                           ##oprobe = 'character') )
    try(dbRemoveTable(con, 'allprobes'), silent = TRUE)
    dbCreateTable(con, name = 'allprobes', c(
                           key = 'integer primary key',
                           probe = 'character unique not null' ) )
    try(dbRemoveTable(con, 'samples'), silent = TRUE)
    dbCreateTable(con, name = 'samples', c(
                           key = 'integer primary key',
                           sample = 'character unique not null' ) )
    try(dbRemoveTable(con, 'tcgaitmp'), silent = TRUE)
    dbCreateTable(con, name = 'tcgaitmp', c(
                           sample = 'character',
                           probe = 'character',
                           value = 'float',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'tcgacatitmp'), silent = TRUE)
    dbCreateTable(con, name = 'tcgacatitmp', c(
                           sample = 'character',
                           probe = 'character',
                           value = 'character',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'probestmp'), silent = TRUE)
    dbCreateTable(con, name = 'probestmp', c(
                           key = 'int',
                           probe = 'character'))
                           ##oprobe = 'character' ) )
    try(dbRemoveTable(con, 'allprobestmp'), silent = TRUE)
    dbCreateTable(con, name = 'allprobestmp', c(
                           key = 'int',
                           probe = 'character' ) )
    try(dbRemoveTable(con, 'samplestmp'), silent = TRUE)
    dbCreateTable(con, name = 'samplestmp', c(
                           key = 'int',
                           sample = 'character' ) )
    try(dbRemoveTable(con, 'types'), silent = TRUE)
    dbCreateTable(con, name = 'types', c(
                           key = 'integer primary key',
                           type = 'character unique not null') )
    try(dbRemoveTable(con, 'nosuffix'), silent = TRUE)
    dbCreateTable(con, name = 'nosuffix', c(
                           type = 'character unique not null') )
}

################################################################
## it **might** be good to add some indexes early on...
## this will slow down register of new probes and samples
## but should make the big tidy load faster?

dbExecute( con, 'create index probesidx on probes ( probe )')
dbExecute( con, 'create index samplesidx on samples ( sample )')

################################################################
## create and also populate table 'clin' here

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
    trim_ws = TRUE)
##  , n_max = my.limit )  
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


try(dbRemoveTable(con, 'clin'), silent = TRUE)
dbWriteTable(con, 'clin', my_clin, row.names = FALSE)
str( dbGetQuery(con,  'select * from clin') )

my_clin = NULL; gc()

################################################################
## read tcga data files

## rna
my_rna = read_tsv('Data/EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz',
    trim_ws = TRUE, n_max = my.limit ) %>%
        rename(probe = sample) %>%
            mutate ( probe = make.unique(as.character(probe), sep = '_' ) )%>%
                gather( sample, value, -probe ) %>%
                    mutate(type = 'rna') %>%
                        select( sample, probe, value, type )
my_rna

tablemaker(my_rna, suffix = FALSE)

my_rna = NULL; gc()

## cnv
my_cnv = read_tsv('Data/broad.mit.edu_PANCAN_Genome_Wide_SNP_6_whitelisted.gene.xena.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnv
my_cnv = my_cnv %>%
    rename(probe = sample) %>%
        mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'cnv') %>%
                    select( sample, probe, value, type )
my_cnv
## sanity checks
dim(my_cnv)
my_cnv %>% filter(probe == 'CDKN2A')
dat = my_cnv; suffix = TRUE; categorical = FALSE; tsep = '.'; deleteType = FALSE; connection = con
tablemaker(my_cnv)

my_cnv = NULL; gc()


## cnc : thresholded gistic copy number
## note: sample is Sample on header of this data set
my_cnc = read_tsv('Data/TCGA.PANCAN.sampleMap__Gistic2_CopyNumber_Gistic2_all_thresholded.by_genes.gz',
    trim_ws = TRUE, n_max = my.limit )
my_cnc
my_cnc = my_cnc %>%
    rename(probe = Sample) %>%
        mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
            gather( sample, value, -probe ) %>%
                mutate(type = 'cnc') %>%
                    select( sample, probe, value, type )
my_cnc
tablemaker(my_cnc)
my_cnc = NULL; gc()


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
            mutate ( probe = make.unique(as.character(probe), sep = '_') ) %>%
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
            mutate ( probe = make.unique(as.character(probe), sep = '_') )  %>%
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
unique(my_molec_subtype$probe)
unique(my_molec_subtype$value)

tablemaker(my_molec_subtype, categorical = TRUE, suffix = FALSE)

dbGetQuery(con, 'select distinct value from tcgacati')

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

##try(dbRemoveTable(con, 'cnv'), silent = TRUE)
dbWriteTable(con, 'cnv', my_cnv, overwrite = TRUE, row.names = FALSE)
my_cnv = NULL; gc()

################################################################
## geography

my_geo = read_tsv('hugo_gencode_good_hg19_V24lift37_probemap',
    trim_ws = TRUE, n_max = my.limit )
my_geo
##try(dbRemoveTable(con, 'geo'), silent = TRUE)
dbWriteTable(con, 'geo', my_geo, overwrite = TRUE, row.names = FALSE)

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
    try(dbExecute(  con,  'drop index mutidx on mutation' ), silent = TRUE)
    try(dbExecute(  con, 'drop index mutationsamplesidx on mutationsamples' ), silent = TRUE)
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

if(mysql){
    dbExecute( con, 'alter table mutation modify gene varchar(35)')
    dbExecute( con, 'alter table mutationsamples modify sample varchar(35)')
}

dbExecute(  con, 'create index mutidx on mutation (gene)' )
dbExecute(  con, 'create index mutationsamplesidx on mutationsamples(sample)' )

##    ## we also need to change text attributes of some tables


dbGetQuery(con, 'select distinct value from tcgacati')

phenos  = dbGetQuery(con, '
select samples.sample, probes.probe, tcgacati.value from tcgacati, probes, samples
where tcgacati.probekey = probes.key
and tcgacati.samplekey = samples.key
and tcgacati.type <> "fmut"
')
str(phenos)
tail(phenos)
table(phenos$value)
table(phenos$Subtype_Selected)
 

phenos = phenos %>% distinct(sample, probe, .keep_all = TRUE) %>% spread(probe, value)
unique(phenos$'_primary_disease')
tail(phenos)
which(duplicated(phenos$sample))
dbWriteTable(con, 'tmptable', phenos, overwrite = TRUE, row.names = FALSE)
clinpheno_intermediate = dbGetQuery(con, '
select * from clin
left join tmptable
on clin.sample = tmptable.sample
')

print(table(clinpheno_intermediate$Subtype_Selected))

## Remove duplicate columns (maybe none) and replace subtype NA values with tumtype.NA
clinpheno_intermediate = clinpheno_intermediate[ , ! duplicated(colnames(clinpheno_intermediate)) ]
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Selected), "Subtype_Selected" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Selected), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_CNA), "Subtype_CNA" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_CNA), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_DNAmeth), "Subtype_DNAmeth" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_DNAmeth), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Immune_Model_Based), "Subtype_Immune_Model_Based" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Immune_Model_Based), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Integrative), "Subtype_Integrative" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Integrative), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_miRNA), "Subtype_miRNA" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_miRNA), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_mRNA), "Subtype_mRNA" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_mRNA), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_other), "Subtype_other" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_other), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_protein), "Subtype_protein" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_protein), "tumtype" ], "NA", sep = '.' )

print(as.data.frame(table(clinpheno_intermediate$Subtype_Selected), exclude = NULL))

try(dbRemoveTable(con, 'clinpheno'), silent = TRUE)
dbWriteTable(con, 'clinpheno', clinpheno_intermediate, row.names = FALSE, overwrite = TRUE)
dbGetQuery(con, 'select distinct Subtype_Selected from clinpheno')


if( mysql ) {
    try(dbExecute( con, 'drop index clinphenoidx on clinpheno') , silent = TRUE)
} else {
    dbExecute( con, 'drop index if exists clinphenoidx')
}

if(mysql) {
    dbExecute( con, 'alter table clinpheno modify sample varchar(35)' )
}

dbExecute( con, 'create index clinphenoidx on clinpheno(sample)' )

str(dbGetQuery(con, 'select * from clinpheno limit 5'))

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

## clinical columns can be used as probes, need to be registered into allprobes

allprobe = data.frame(
    key = NA,
    probe = colnames(dbGetQuery(con, 'select * from clin limit 1'))
    )
dbWriteTable(con, 'allprobes', allprobe, append = TRUE, row.names = FALSE)


## massage the cohorts table
clintmpclean  = dbGetQuery(con, 'select tumtype, cohort from clin')  %>% drop_na %>% distinct
clintmpclean$string = with( clintmpclean, paste(cohort, '(', tumtype, ')' ) )
clintmpclean = clintmpclean %>% rename(cohort = tumtype, lcohort = cohort, cohortstring = string)

try(dbRemoveTable(con, 'cohorts'))
dbWriteTable(con, 'cohorts', clintmpclean, row.names = FALSE)
dbGetQuery(con, 'select * from cohorts')

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
