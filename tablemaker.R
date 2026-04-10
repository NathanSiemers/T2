################################################################
## master function for creating tidy data tables
## where probe and sample keys are integer sequences
## with separate probe and sample lookup tables

tablemaker = function( dat, connection = con, categorical = FALSE, suffix = TRUE, tsep = '.', deleteType = TRUE, sparse = TRUE, r_datatype = NULL ) {
    thistype = dat$type[[1]]  ## there can be only one
    ## input: a tidy data set of sample, probe, value, type
    ## convert sample and probe into integer keys while updating:
    ##      samples and probes tables with key relationships
    ## data goes into tcgai or tcgacati depending on numeric or categorical
    Q = function( query ){
        as_tibble(do.call(dbGetQuery, list( con = connection, statement = query ) ))
    }
    if( categorical ) {
        dest_table = 'tcgacati'
    } else {
        dest_table = 'tcgai'
    }
    cat(sprintf("tablemaker: type=%s dest=%s sparse=%s suffix=%s\n", thistype, dest_table, sparse, suffix))

    ## add to "tested" table
    the_type = dat$type[[1]]
    mytested = data.frame(
      sample = dat$sample,
      value = 1,
      type = dat$type
    ) %>% distinct(sample, value, type)
    dbExecute(connection, paste0( 'delete from tested where type = "', the_type, '"' ))
    clin = Q('select * from clin')
    mytested$type = the_type
    cat(sprintf("  tested: %d samples\n", nrow(mytested)))
    dbWriteTable(con, name="tested", value=mytested, append=TRUE)

    ## SAMPLES - add any new sample keys
    usample = dat %>% dplyr::select( sample ) %>%
        distinct %>%
            mutate( key = NA ) %>%
                dplyr::select( key, sample )
    dbWriteTable(connection, 'samplestmp', usample, append = TRUE, row.names = FALSE)
    if(mysql){
        dbExecute(connection, 'insert ignore into samples select "key", sample from samplestmp')
    } else {
        dbExecute(connection, 'insert OR ignore into samples select key, sample from samplestmp')
    }
    dbExecute(connection, 'delete from samplestmp')

    ## PROBES - add any new probe keys
    uprobe = dat %>%
        { if(suffix) mutate(., probe = paste(probe, type, sep = tsep)) else . } %>%
            select ( probe ) %>%
                distinct %>%
                    mutate( key = NA ) %>%
                        select(key, probe)
    cat(sprintf("  probes: %d unique\n", nrow(uprobe)))
    print(head(uprobe, 3))
    allprobe = uprobe %>% select(key, probe)
    dbWriteTable(connection, 'probestmp', uprobe, overwrite = TRUE, row.names = FALSE)
    if(mysql){
        dbExecute(connection, 'insert ignore into probes select *  from probestmp')
    } else {
        dbExecute(connection, 'insert OR ignore into probes select key, probe from probestmp')
    }
    dbExecute(connection, 'delete from probestmp')
    dbWriteTable(connection, 'allprobestmp', allprobe, overwrite = TRUE, row.names = FALSE)
    if(mysql){
        dbExecute(connection, 'insert ignore into allprobes select `key`, probe from allprobestmp')
    } else {
        dbExecute(connection, 'insert OR ignore into allprobes select `key`, probe from allprobestmp')
    }
    dbExecute(connection, 'delete from allprobestmp')

    ## TYPE - delete old rows and register type
    if( deleteType ) {
        cat(sprintf("  deleting old type '%s' from %s\n", thistype, dest_table))
        dbExecute(connection, paste0('delete from ', dest_table, ' where type = "', thistype, '"'))
        dbExecute(connection, paste0( 'delete from types where type = "', thistype, '"' ))
        dbExecute(connection, paste0( 'delete from nosuffix where type = "', thistype, '"' ))
    }
    if(mysql){
        dbExecute(connection, paste0('insert ignore into types values ( NULL, "', thistype, '" )' ) )
    } else {
        dbExecute(connection, paste0('insert OR ignore into types values ( NULL, "', thistype, '" )' ) )
    }
    if( ! suffix ) {
        if(mysql){
            dbExecute(connection, paste0('insert ignore into nosuffix values ( "', thistype, '" )'  ) )
        } else {
            dbExecute(connection, paste0('insert OR ignore into nosuffix values ( "', thistype, '" )'  ) )
        }
    }

    ## DATATYPES - register R class for this type
    effective_datatype = if (!is.null(r_datatype)) r_datatype
                         else if (categorical) "factor"
                         else "numeric"
    if(deleteType) {
        dbExecute(connection, paste0('delete from datatypes where type = "', thistype, '"'))
    }
    if(mysql){
        dbExecute(connection, paste0('insert ignore into datatypes values ( "',
                                     thistype, '", "', effective_datatype, '" )'  ) )
    } else {
        dbExecute(connection, paste0('insert OR ignore into datatypes values ( "',
                                     thistype, '", "', effective_datatype, '" )'  ) )
    }
    cat(sprintf("  r_datatype: %s\n", effective_datatype))

    ## INSERT INTO CORE TIDY TABLE
    ## filter zeros if sparse
    if(sparse){
      cat(sprintf("  sparse: removing %d zeros, preserving %d NAs\n",
                  sum(dat$value == 0, na.rm = TRUE), sum(is.na(dat$value))))
      dat = dat %>% filter( value != 0 | is.na(value) )
    }
    if(suffix) {
      dat = dat %>% mutate(probe = paste(probe, type, sep = '.') )
    }
    cat(sprintf("  inserting %d rows into %s\n", nrow(dat), dest_table))
    print(head(dat, 3))

    dest_tmp = paste0(dest_table, 'tmp')
    dbExecute(connection, paste('delete from', dest_tmp) )
    if(mysql){
        dbWriteTable(connection, dest_tmp, dat, header = TRUE, append = FALSE, overwrite = TRUE, row.names = FALSE )
    } else {
        dbWriteTable(connection, dest_tmp, dat, append = FALSE, overwrite = TRUE, row.names = FALSE )
    }

    sqljoin = paste0('select samples.key as samplekey, probes.key as probekey, value, type from ',
                     dest_tmp, ' left join samples on ', dest_tmp, '.sample = samples.sample',
                     ' left join probes on ', dest_tmp, '.probe = probes.probe ')
    sql_string = paste('insert into', dest_table, sqljoin)
    cat(sprintf("  %s\n", sql_string))
    dbExecute(connection, sql_string)
    dbExecute(connection, paste('delete from', dest_tmp) )
    cat(sprintf("  done: %s\n", thistype))
}
