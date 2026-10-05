################################################################
## The default_filters table: ready-made sample subsets a client offers as
## one-tap choices (see ../default_filters.R for the table's shape and the
## definitions; edit them there).

source('../default_filters.R')
write_default_filters(con, 'TCGA')
