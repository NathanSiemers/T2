library(tidyverse)
library(sqldf)
source('tablemaker.R')

if( TESTING ) {
    my.limit = TESTINGLINES
} else {
    my.limit = Inf
}    


Q = function( query ){
    as_tibble(do.call(dbGetQuery, list( con = con, statement = query ) ))
}

ignore = function(mysql) {
    if (mysql) {
        return ( ' IGNORE ' )
    } else {
        return ( ' OR IGNORE ')
    }
}

indextable = function(mytable, mysql) {
    if(mysql){
        return(paste( "ON", mytable ) )
    } else {
        return("")
    }
}

qwc = function(...) { as.character( unlist( as.list( match.call() )[ -1 ] ) ) }



################################################################
## Samples that occur more than once in a source file (two aliquots of one
## sample barcode). Left alone, the file readers rename the copies
## ("TCGA-21-1076-01...3746", "..._1", "...-1"), the renamed copies match
## nothing in the clinical table, and the real sample ends up with no data of
## that type. Rule (owner's decision, 2026-10-05): ONE value per sample, the
## MEAN of the copies (a copy that is NA is ignored; NA only if all are NA).
## Every wide loader reads with name_repair = 'minimal' (names untouched) and
## calls average_duplicate_columns() before anything else; loaders with one row
## per sample call average_duplicate_rows(). tablemaker() refuses renamed copies.

## wide data: one column per sample, any number of leading id columns
average_duplicate_columns = function(wide, what = 'data') {
    nm = names(wide)
    empty = which(is.na(nm) | nm == '')  # an unnamed id column gets readr's usual name
    nm[empty] = paste0('...', empty)
    cols = as.list(wide)                 # by position: duplicated names are fine in a list
    names(cols) = nm
    dup = unique(nm[duplicated(nm)])
    if (length(dup) == 0) {
        cat(sprintf("%s: no sample column appears more than once\n", what))
        return(tibble::as_tibble(cols, .name_repair = 'check_unique'))
    }
    drop = integer(0)
    for (d in dup) {
        idx = which(nm == d)
        m = rowMeans(do.call(cbind, lapply(cols[idx], as.numeric)), na.rm = TRUE)
        m[is.nan(m)] = NA
        cols[[idx[1]]] = m
        drop = c(drop, idx[-1])
    }
    cat(sprintf("%s: %d sample(s) appear more than once and were averaged: %s\n",
                what, length(dup), paste(dup, collapse = ', ')))
    tibble::as_tibble(cols[-drop], .name_repair = 'check_unique')
}

## long data (sample, probe, value, ...): one value per (sample, probe)
average_duplicate_rows = function(long, what = 'data') {
    n_dup = sum(duplicated(long[, c('sample', 'probe')]))
    if (n_dup == 0) {
        cat(sprintf("%s: no (sample, probe) pair appears more than once\n", what))
        return(long)
    }
    dup_samples = unique(long$sample[duplicated(long[, c('sample', 'probe')])])
    cat(sprintf("%s: %d sample(s) appear more than once and were averaged: %s\n", what, length(dup_samples),
                paste(head(dup_samples, 30), collapse = ', ')))
    others = setdiff(names(long), c('sample', 'probe', 'value'))
    long %>% group_by(across(all_of(c('sample', 'probe', others)))) %>%
        summarise(value = if (all(is.na(value))) NA_real_ else mean(value, na.rm = TRUE), .groups = 'drop')
}
