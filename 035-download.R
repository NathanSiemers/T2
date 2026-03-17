library(tidyverse)

if( download ) {
    try(system('mkdir Data'), silent = TRUE)
    if (! require('UCSCXenaTools') ) install.packages("UCSCXenaTools")
    ##devtools::install_github("ropensci/UCSCXenaTools")
    library(UCSCXenaTools)
    ## for now, omit large exon and methylation data sets
    mytypes = showTCGA(project = "PANCAN")$DataType
    mytypes = mytypes[ ! mytypes %in% c('DNA Methylation', 'Exon Expression RNASeq') ]
    ##mytypes = mytypes[ ! mytypes %in% c('DNA Methylation') ]
    mytypes
    downloadTCGA(project = "PANCAN",
                 ##data_type = mytypes,
                 data_type = availTCGA("DataType"),
                 trans_slash = TRUE,
                 ##force = xena.force,
                 force = TRUE,
                 ##file_type = showTCGA(project = "PANCAN")$FileType,
                 file_type = availTCGA("FileType"),
                 destdir = "./Data",
                 method = 'wget'
                 )
}
