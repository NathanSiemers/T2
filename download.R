try(system('mkdir Data'))

install.packages("UCSCXenaTools")
library(tidyverse)
library(UCSCXenaTools)


## for now, omit large exon and methylation data sets

mytypes = showTCGA(project = "PANCAN")$DataType
mytypes = mytypes[ ! mytypes %in% c('DNA Methylation', 'Exon Expression RNASeq') ]
mytypes



downloadTCGA(project = "PANCAN",
             data_type = mytypes,
             file_type = showTCGA(project = "PANCAN")$FileType,
             destdir = "./Data",
             )

