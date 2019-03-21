## Nathan Siemers
files = c(
    'download.R',
    'create_db.R',
    'add_signatures_to_db.R'
    )

## make simpler for now
## library(rmarkdown)
## lapply( files, function( thefile ) {
##     render( thefile, pdf_document() )
## })

lapply( files, source, echo = TRUE, max.deparse.length = 20000 )

sessionInfo()
