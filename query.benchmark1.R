library(tidyverse)
library(RMySQL)
if(FALSE){
    db = '../T2local/tcga.db'
    con2 = RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RW )
}
con = RMySQL::dbConnect (
    drv       = RMySQL::MySQL(),
    dbname    = "pancan2018",
    host      = "pancan2018.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
    port      = 3306,
    username  = "admin",
    password  = "Adminuser19")


dbGetQuery(con, 'set profiling = 1')
myprobes = dbGetQuery(con, 'select probe from probes')$probe
mytypes = c('rna', 'cnc', 'cnv', 'mut')
tcgas = tbl(con, 'tcgas')
qh = function(x, conn = con) {
    query = paste0('
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai, samples, probes
where probe in ( "', paste(x, collapse = '" ,"'), '" ) and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )
    ##print(query)
    dbGetQuery(conn, query)
}
qrna = function(x, conn = con) {
    query = paste0('
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai, samples, probes
where probe in ( "', paste(x, collapse = '" ,"'), '" ) and tcgai.type = "rna" and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )
    ##print(query)
    out = dbGetQuery(conn, query)
    print(nrow(out))
    out
}
qtype = function(x, type, conn = con) {
    print(paste(x,type))
    query = paste0('
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai, samples, probes
where probe  = "', x, '"  and tcgai.type = "', type, '" and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )
    ##print(query)
    out = dbGetQuery(conn, query)
    print(nrow(out))
    out
}
qtypel = function(x, type, conn = con) {
    print(paste(x,type))
    query = paste0('explain 
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai, samples, probes
where ',
        paste( paste0(' ( probe ="', x, '" and type = "', type, '" )' ), collapse = ' OR ' ),
        ' and tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )
    print(query)
    out = dbGetQuery(conn, query)
    print(nrow(out))
    out
}

qtypelj.old = function(x, conn = con) {
    print(paste(x))
    query = paste0('
select sample, probe, value, type from ( select * from probes where probe in ( "', paste(x, collapse = '" ,"'), '" ) ) as p  
left join tcgai  on
p.key = tcgai.probekey
left join samples on
samplekey = samples.key
where ',
        paste( paste0(' ( probe ="', x, '" )' ), collapse = ' OR ' )
        )
    print(query)
    out = as_tibble(dbGetQuery(conn, query))
    print(nrow(out))
    out
}

qtypelj = function(x, conn = con) {
    print(paste(x))
    query = paste0('
select sample, probe, value, type from ( select * from probes where probe in ( "', paste(x, collapse = '" ,"'), '" ) ) as p  
left join tcgai  on
p.key = tcgai.probekey
left join samples on
samplekey = samples.key
where ',
        paste( paste0(' ( probe ="', x, '" )' ), collapse = ' OR ' )
        )
    print(query)
    out = as_tibble(dbGetQuery(conn, query))
    print(nrow(out))
    out
}

## tests
n = 10
nprobes = 40

elapsed1 = sapply(1:n, function(x){print(   system.time(qtypelj( sample( myprobes, nprobes ) ) ) ["elapsed"] ) } )
ggplot2::qplot(elapsed1)
summary(elapsed1)

elapsed2 = sapply(1:n, function(x){
    p = sample(myprobes, nprobes)
    print(   system.time(tcgas %>% filter( probe %in% p ) %>% collect)  ["elapsed"] )
    Sys.sleep(10)
})

    
ggplot2::qplot(elapsed2)
summary(elapsed2)

sapply(1:n, function(x){print(head(qrna( sample(myprobes, 1) ) , 3 ) ) } ) 

n = 10
nprobes = 1
##print('sqlite')
##system.time( sapply(1:n, function(x){ qh( sample(myprobes, nprobes), conn = con2 ) } ) )
print('mysql')
system.time( sapply(1:n, function(x){ qh( sample(myprobes, nprobes) ) } ) )


## elapsed = sapply(1:n, function(x){print(   system.time(qrna( sample(myprobes, 5) ) )["elapsed"]  ) } ) 

## elapsed = sapply(1:n, function(x){print(   system.time(qtype( sample(myprobes, 1), sample(mytypes, 1) ) )["elapsed"]  ) } ) 

## dim(qtypelj( sample(myprobes, 4), sample(mytypes, 4) ))

## elapsed = sapply(1:n, function(x){print(   system.time(qtypelj( sample(myprobes, 4), sample(mytypes, 4) ) )["elapsed"]  ) } )
## ggplot2::qplot(elapsed)

