################################################################
## master function for creating tidy data tables
## where probe and sample keys are integer sequences
## with separate probe and sample lookup tables
library(sqldf)

tablemaker = function( data, db = 'tcga.db', categorical = FALSE, suffix = TRUE, tsep = '.', deleteType = FALSE ) {
    ## input: a tidy data set of sample, probe, value, type
    ## convert sample and probe into integer keys while updating:
    ##      sampleykeys and probes tables
    ## data goes into tcgai or tcgacati depending on numeric or categorical
    print(db)
    if( categorical ) {
        dest_table = 'tcgacati'
        print("destination table tcgacati")
    } else {
        dest_table = 'tcgai'
        print("destination table tcgai")
    }
    ## ################################################################
    ## SAMPLES
    ## add any new sample keys to samples
    ## make two-column table with key column = NA
    ## sqlite will sequence keys for you
    usample = data %>% select( sample ) %>%
        distinct %>%
            mutate( key = NA ) %>%
                select( key, sample )
    sqldf('insert or ignore into samples select key, sample from usample', db = db )
    print( sqldf( 'select * from samples limit 2', db = db ) )
    ## ################################################################
    ## PROBES
    ## add any new probe keys to probes
    ## same method as sample keys
    uprobe = data %>%
        mutate( key = NA ) %>%
            select( key, probe ) %>%
                distinct
    ## add .type suffix probe names to allprobes if desired
    ## i.e. ABCA1.mut, CDKN2A.cnv
    ## these are names people will be offered in menus, etc
    if ( suffix ) {
        print('with suffix')
        allprobe = data %>%
            mutate( newprobe = paste( probe, type, sep = tsep ) ) %>%
                mutate( key = NA, probe = newprobe ) %>%
                    select( key, probe ) %>%
                        distinct
        print('allprobe')
        print(allprobe)
    } 
    else {
        print('without suffix')
        allprobe = uprobe
        print('allprobe')
        print(allprobe)
    }
    sqldf('insert or ignore into probes select key, probe from uprobe', db = db )
    print('probes')
    print( sqldf( 'select * from probes limit 5', db = db ) )
    sqldf('insert or ignore into allprobes select key, probe from allprobe', db = db )
    print('allprobes')
    print( sqldf( 'select * from allprobes limit 5', db = db ) )
    ## ################################################################
    ## TYPE of data
    ## delete old rows of TYPE if requested
    ## YOU SHOULD BE CAREFUL WITH THIS
    ## old sample and probe keys will hang around forerver for now
    mytype = data %>% distinct(type); mytype = mytype[[1]]
    print('mytype')
    print(mytype)
    if( deleteType ) {
        print(paste('DELETING TYPE', mytype, 'from table', dest_table))
        sqldf(paste(
            'delete from',
            dest_table,
            'where type = "',
            mytype, '"'
            ), db = db)
    }
    ## ################################################################
    ## INSERT INTO CORE TIDY TABLE
    print('Data')
    print(head(data))
    sql_select = paste('
select samples.key as samplekey, probes.key as probekey, data.value, data.type
from data
inner join samples on samples.sample = data.sample
inner join probes on probes.probe = data.probe
' )
    sql_string =  paste(
        'insert into',
        dest_table,
        sql_select )
    print(sql_string)
    sqldf(sql_string, db = db)
}
