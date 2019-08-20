library(tidyverse)

if( download ) {
    try(system('mkdir Data'), silent = TRUE)
    if (! require('UCSCXenaTools') ) install.packages("UCSCXenaTools")
    library(UCSCXenaTools)
    ## for now, omit large exon and methylation data sets
    mytypes = showTCGA(project = "PANCAN")$DataType
    ##mytypes = mytypes[ ! mytypes %in% c('DNA Methylation', 'Exon Expression RNASeq') ]
    mytypes = mytypes[ ! mytypes %in% c('DNA Methylation') ]
    mytypes
    downloadTCGA(project = "PANCAN",
                 data_type = mytypes,
                 trans_slash = TRUE,
                 force = xena.force,
                 file_type = showTCGA(project = "PANCAN")$FileType,
                 destdir = "./Data",
                 )

}
