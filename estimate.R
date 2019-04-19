################################################################
## this is not going to be pretty

library(tidyverse)
library(utils)
rforge <- "http://r-forge.r-project.org"
install.packages("estimate", repos=rforge, dependencies=TRUE)
library(estimate)
source('tablemaker.R')
db = 'tcga.db'
my.limit = Inf

rna_file = 'Data/EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena.gz'

my_rna = read.csv(rna_file, stringsAsFactors = FALSE, sep = '\t', check.names = FALSE)
my_rna[1:5,1:5]
rownames(my_rna) = make.unique(my_rna$sample)
my_rna$sample = NULL

## roll my own filter. filterCommonGenes is corrupting the sample names
##filterCommonGenes( 'Data/rna.tmp', 'Data/estimatein.tmp', id = "GeneSymbol" )
my_filtered = my_rna[ rownames(my_rna) %in% estimate::common_genes$GeneSymbol , ]
dim(my_filtered)

## write gct file
outputGCT(my_filtered, 'Data/rna.tmp')
## run estimate
estimateScore('Data/rna.tmp',
              'Data/estimateout.tmp',
              platform = 'illumina' )

## read estimate results
my_estimate = read.delim('Data/estimateout.tmp', skip = 2, stringsAsFactors = FALSE, sep = '\t')
my_estimate[1:3,1:5]
dim(my_estimate)
dim(my_filtered)

## prep for db loading
my_load = my_estimate %>%
    select(-Description) %>%
        rename(probe = NAME) %>%
            gather( sample, value, -probe ) %>%
                mutate( type = 'estimate' ) %>%
                    mutate ( sample = gsub('.', '-', sample, fixed = TRUE)  ) %>% 
                    select(sample, probe, value, type)


str(my_load)

head(my_load)
dim(my_load)


tablemaker( my_load, deleteType = TRUE, suffix = TRUE)

sqldf::sqldf('select * from tcgas where type = "estimate" limit 10', db = db )

sqldf::sqldf('select * from tcgas where probe = "StromalScore.estimate" and type = "estimate" limit 2', db = db )

system('rm Data/rna.tmp Data/estimatein.tmp Data/estimateout.tmp')









