################################################################
## master function for creating tidy data tables
## where probe and sample keys are integer sequences
## with separate probe and sample lookup tables
##library(DBI)

tablemaker = function( dat, connection = con, categorical = FALSE, suffix = TRUE, tsep = '.', deleteType = TRUE, sparse = TRUE, r_datatype = NULL ) {
    thistype = dat$type[[1]]  ## there can be only one
    ## input: a tidy data set of sample, probe, value, type
    ## convert sample and probe into integer keys while updating:
    ##      samples and probes tables with key relationships
    ## data goes into tcgai or tcgacati depending on numeric or categorical
    Q = function( query ){
        as_tibble(do.call(dbGetQuery, list( con = connection, statement = query ) ))
    }
    print(connection)
    if( categorical ) {
        dest_table = 'tcgacati'
        print("destination table tcgacati")
    } else {
        dest_table = 'tcgai'
        print("destination table tcgai")
    }
    ### first thing (before any 'sparse' filtering)
    ### also a good thing even without sparse filtering
    # this is where we should add to a "tested" table
    # sample value type
    # value = 1 means sample was tested/has a value in this 'type'
    # value = 0 means sample wasn't tested/annotated in this 'type
    print("adding to table: tested")
    the_type = dat$type[[1]]
    mytested = data.frame(
      sample = dat$sample,
      value = 1,
      type = dat$type 
    ) %>% distinct(sample, value, type) 
  ## 
    print("NUMBER OF SAMPLES TESTED")
    dim(mytested)
    ## right now were are always deleting old rows with same 'type'
    sql_string = paste0( 'delete from tested where type = "', the_type, '"' )
    dbExecute(connection, sql_string)
    #' let's build the table in dplyr
    #' but we need clin from db
    #' WHY DO WE NEED CLIN? THIS WILL ADD ALL SAMPLES TO TESTED????!!!!
    clin = Q('select * from clin')
    ##mytested = clin %>% select(sample) %>%
    ##  left_join(mytested, by = join_by(sample)) 
    print(mytested)
    mytested$type = the_type
    ##mytested[is.na(mytested$value), "value"] = 0
    print(mytested)
    print("samples assayed in this type")
    print(table(mytested$value, exclude = FALSE))
    dbWriteTable(con, name="tested", value=mytested, append=TRUE)
    ## ################################################################
    ## SAMPLES
    ## add any new sample keys to samples
    ## make two-column table with key column = NA
    ## sqlite will sequence keys for you
    usample = dat %>% dplyr::select( sample ) %>%
        distinct %>%
            mutate( key = NA ) %>%
                dplyr::select( key, sample )
    print('writing to sample index table (samples)' )
    print(head(usample))
    ## write usample to temporary table in db (samplestmp)
    dbWriteTable(connection, 'samplestmp', usample, append = TRUE, row.names = FALSE)
    ## insert any new samples into samples table
    if(mysql){
        dbExecute(connection, 'insert ignore into samples select "key", sample from samplestmp')
    } else {
        dbExecute(connection, 'insert OR ignore into samples select key, sample from samplestmp')
    }
    dbExecute(connection, 'delete from samplestmp')
    ## ################################################################
    ## PROBES
    ## add any new probe keys to probes
    ## same method as sample keys
    uprobe = dat %>%
        mutate(  probe = case_when(
                     suffix == TRUE ~ paste( probe, type, sep = tsep ),
                     TRUE ~ probe ) ) %>%
                         ##select ( probe, oprobe ) %>%
                         select ( probe ) %>%
                             distinct %>%
                                 mutate( key = NA ) %>%
                                     ##select(key, probe, oprobe)
                                     select(key, probe)
    print("UPROBE")
    print(head(uprobe))
    ## to allprobes if desired i.e. ABCA1.mut, CDKN2A.cnv these are
    ## names people will be offered in menus, etc
    allprobe = uprobe %>% select(key, probe)
    ## insert or ignore into probes
    ## write temporary table to db
    ## insert any new probes into probe
    print('dbwrite probestmp')
    dbWriteTable(connection, 'probestmp', uprobe, overwrite = TRUE, row.names = FALSE)
    print('probestmp')
    print('probes')
    print('sanity checking: length, unique, head')
    Q('select * from probes limit 5')
    ptmp = pull( Q('select probe from probestmp'), 'probe') ; print(length(ptmp)); print(length(unique(ptmp)));print(head(ptmp)); 
    ptot = pull( Q('select probe from probes'), 'probe'); length(ptot); head(ptot)
    print("intersection of tmp file with probes")
    print(length(which( ptmp %in% ptot )))
    if(mysql){
        ##dbExecute(connection, 'insert ignore into probes select probestmp.key, probe, oprobe  from probestmp')
        dbExecute(connection, 'insert ignore into probes select *  from probestmp')
    } else {
        ##dbExecute(connection, 'insert OR ignore into probes select probestmp.key, probe, oprobe from probestmp')
        dbExecute(connection, 'insert OR ignore into probes select key, probe from probestmp')
    }
    dbExecute(connection, 'delete from probestmp')
    ##sqldf('insert or ignore into probes select key, probe from uprobe', connection = con )
    ## insert or ignore into allprobes
    print('allprobes')
    print('dbwrite allprobestmp')
    dbWriteTable(connection, 'allprobestmp', allprobe, overwrite = TRUE, row.names = FALSE)
    if(mysql){
        dbExecute(connection, 'insert ignore into allprobes select `key`, probe from allprobestmp')
    } else {
        dbExecute(connection, 'insert OR ignore into allprobes select `key`, probe from allprobestmp')
    }
    dbExecute(connection, 'delete from allprobestmp')
    print( dbGetQuery(connection,  'select * from allprobes limit 5') )
    ## ################################################################
    ## TYPE of dat
    ## delete old rows of TYPE if requested
    ## YOU SHOULD BE CAREFUL WITH THIS
    ## old sample and probe keys will hang around forerver for now
    ## needs to be improved.
    if( deleteType ) {
        print(paste('DELETING TYPE', thistype, 'from table', dest_table))
        print(Q('select distinct type from types'))
        query = paste0(
            'delete from ',
            dest_table,
            ' where type = "',
            thistype, '"'
            )
        print(query)
        dbExecute(connection, query)
        dbExecute(connection, paste0( 'delete from types where type = "', thistype, '"' ))
        dbExecute(connection, paste0( 'delete from nosuffix where type = "', thistype, '"' ))
    }
        ##  insert type into types table if it doesn't exist
    if(mysql){
        dbExecute(connection, paste0(
            'insert ignore into types values ( NULL, "',
            thistype, '" )' ) )
    } else {
        dbExecute(connection, paste0(
            'insert OR ignore into types values ( NULL, "',
            thistype, '" )'  ) )
    }
    ## insert into nosuffix table
    if( ! suffix ) {
        if(mysql){
            dbExecute(connection, paste0('insert ignore into nosuffix values ( "',
                                         thistype, '" )'  ) )
        } else {
            dbExecute(connection, paste0('insert OR ignore into nosuffix values ( "',
                                         thistype, '" )'  ) )
        }
    }

    ## insert into datatypes table
    ## default: categorical -> factor, numeric -> numeric
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
    print(paste("R datatype for", thistype, ":", effective_datatype))

    ## ################################################################
    ## INSERT INTO CORE TIDY TABLE
    ##
    ## FIRST, filter dat if sparse=TRUE
    print('dat')
    print(head(dat))
    if(sparse){
      print("filtering zeros from result (sparse representation)")
      print(paste("  NAs in source data:", sum(is.na(dat$value))))
      print(paste("  zeros in source data:", sum(dat$value == 0, na.rm = TRUE)))
      dat = dat %>% filter( value != 0 | is.na(value) )
    }
    
    print("transform dat probe to probe.type if suffix = TRUE")
    if(suffix) {
      dat = dat %>% mutate(probe = paste(probe, type, sep = '.') )
    }
    print(as_tibble(dat))
    print('write dat as tcga(cat)itmp on server')
    dest_tmp = paste0(dest_table, 'tmp')
    print(dest_tmp)
    ## just to make sure
    dbExecute(connection, paste('delete from', dest_tmp) )
    print('there should be nothing below')
    print( dbGetQuery(connection, paste('select * from',  dest_tmp,  'limit 5') ) )
    print('starting db write')
    if(mysql){
        dbWriteTable(connection, dest_tmp, dat, header = TRUE, append = FALSE, overwrite = TRUE, row.names = FALSE )
    } else {
        dbWriteTable(connection, dest_tmp, dat, append = FALSE, overwrite = TRUE, row.names = FALSE )
    }
    Q(paste('select * from', dest_tmp, 'limit 3'))
    print('db write of temp table complete')
    print('insert tmpdata into core tidy tables')

    sqljoin = paste0('select samples.key as samplekey, probes.key as probekey,  value, type from ', dest_tmp, ' left join samples on ', dest_tmp, '.sample = samples.sample left join probes on ', dest_tmp, '.probe = probes.probe ')
    
    print(sqljoin)
    ##     sql_select = paste0('
    ## select samples.key as samplekey, probes.key as probekey, ', dest_tmp, '.value, ',  dest_tmp, '.type
    ## from ', dest_tmp, ' 
    ## inner join samples on samples.sample = ', dest_tmp, '.sample
    ## inner join probes on probes.probe = ', dest_tmp, '.probe
    ## ' )
    sql_string =  paste(
      'insert into',
      dest_table,
      sqljoin )
    print(sql_string)
    dbExecute(connection, sql_string)
    dbExecute(connection, paste('delete from', dest_tmp) )
    ##############################################
    
}

