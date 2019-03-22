## Nathan Siemers
files = c(
    'download.R',
    'create_db.R',
    'add_signatures_to_db.R',
    'add_TMB.R'
    )

lapply( files, source, echo = TRUE, max.deparse.length = 20000 )

sessionInfo()
