try(system('mkdir Data'))

install.packages("UCSCXenaTools")
library(UCSCXenaTools)

availTCGA("ProjectID")
availTCGA("FileType")

showTCGA(project = "PANCAN")

downloadTCGA(project = "PANCAN",
             data_type = showTCGA(project = "PANCAN")$DataType,
             file_type = showTCGA(project = "PANCAN")$FileType,
             destdir = "./Data",
             )
