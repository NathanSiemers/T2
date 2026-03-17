library(sqldf)
db = '../T2local/tcga.db'

con2 = RSQLite::dbConnect(RSQLite::SQLite(), dbname = db, flags = RSQLite::SQLITE_RW )
library(RMySQL)
library(DBI)
con = RMySQL::dbConnect (
    drv       = RMySQL::MySQL(),
    dbname    = "pancan2018dev",
    host      = "pancan2018dev.cbe7mtbvwi2d.us-east-1.rds.amazonaws.com",
    port      = 3306,
    username  = "admin",
    password  = "Adminuser19")

## idxp2
## idxprobehash

dbGetQuery(con, 'set profiling = 1')

myprobes = dbGetQuery(con, 'select probe from probes')$probe

qh = function(x, conn = con) {
    query = paste0('
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai, samples, probes
where probe in ( "', paste(x, collapse = '" ,"'), '" ) and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )
    ##print(query)
    dbGetQuery(conn, query)
}

qtcgai = function(x, conn = con) {
    query = paste0('
select * from tcgai
where probekey in ( "', paste(x, collapse = '" ,"'), '" )' )
    print(query)
#    print(dbGetQuery(con, paste('explain', query) ) )
    out = dbGetQuery(conn, query)
    cat('.')
    out
}

qhleft = function(x) {
    query = paste0('
select sample, probe, value, type from ( select * from probes where probe in ( "', paste(x, collapse = '" ,"'), '" ) ) as p  
left join tcgai  on
p.key = tcgai.probekey
left join samples on
samplekey = samples.key
' )
    ##print(query)
    ##print(dbGetQuery(con, paste('explain', query) ) )
    out = dbGetQuery(con, query)
    cat('.')
    out
}

qtype = function(x) {
    query = paste0('
select sample, probe, value, type from ( select * from probes where probe in ( "', paste(x, collapse = '" ,"'), '" ) ) as p  
left join 
tcgai  on
p.key = tcgai.probekey
left join samples on
samplekey = samples.key
' )
    ##print(query)
    print(dbGetQuery(con, paste('explain', query) ) )
    out = dbGetQuery(con, query)
    cat('.')
    out
}

qhleft2 = function(x) {
    query = paste0('
select samplekey, probe, value, type from ( select * from probes where probe in ( "', paste(x, collapse = '" ,"'), '" ) ) as p  
left join tcgai  on
p.key = tcgai.probekey
' )
##left join samples on
##tcgai.samplekey = samples.key
    ##print(query)
    out = dbGetQuery(con, query)
    cat('.')
    out
}


qnh = function(x) {
    dbGetQuery(con, paste0('
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai use index ( tcgaidxp2 ), samples, probes
where probe = "', x, '" and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' ))
}

qv = function(x) {
    dbGetQuery(con, paste0('
select * from tcgas 
where probe = "', x, '"' ) )
}


dbGetQuery(con,'
explain
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai , samples, probes
where probe = "ABCA1" and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )


dbGetQuery(con,'
explain
select samples.sample, probes.probe, tcgai.value, tcgai.type from tcgai use index ( tcgaidxprobehash ), samples, probes
where probe = "ABCA1" and
tcgai.samplekey = samples.key and tcgai.probekey = probes.key' )

dim(qh('ABCA1'))
dim(qh('ABCA1', conn = con2))




sapply(sample(myprobes, 20), function(x){ print(x); print(system.time(qh(x))) })

library(tidyverse)
tcgai = tbl(con, 'tcgai')
samples = tbl(con, 'samples')
probes = tbl(con, 'probes')

head(tcgai)

tcgai %>% filter(probekey == 1)

probes %>% filter(probe == 'ABCA1') %>% rename( probekey = key)

probes %>%
    filter(probe == 'ABCA1') %>%
        rename(probekey = key) %>% 
            inner_join(tcgai) %>%
                inner_join( samples %>% rename(samplekey = key) ) %>%
                    select( -probekey, -samplekey) 
probes %>%
    filter(probe == 'ABCA1') %>%
        rename(probekey = key) %>% 
            inner_join(tcgai) %>%
                inner_join( samples %>% rename(samplekey = key) ) %>%
                    select( -probekey, -samplekey) %>%
                        explain


qdplyr = function(x){
    probes %>%
        filter(probe == x) %>%
            rename(probekey = key) %>% 
                inner_join(tcgai, by = "probekey") %>%
                    inner_join( samples %>% rename(samplekey = key), by = "samplekey" ) %>%
                        select( -probekey, -samplekey) %>%
                            collect
}

qdplyr2 = function(x){
    probes %>%
        filter(probe %in% x) %>%
            rename(probekey = key) %>% 
                left_join(tcgai, by = "probekey")  %>%
                    left_join( samples %>% rename(samplekey = key), by = "samplekey" ) %>%
                        select( -probekey, -samplekey) %>%
                            ##collect
                            compute
}
    
head(qdplyr('ABCA1'))
head(qdplyr2('ABCA1'))
qdplyr('ABCA1')
qdplyr2('ABCA1')

qdplyr('ABCA1') %>% select(sample) %>% distinct %>% nrow
qdplyr2('ABCA1') %>% select(sample) %>% distinct %>% nrow


out = sapply(sample(myprobes, 1), function(x){ print(system.time(print(head(qdplyr(x), 2)))) } )


indexi = dbGetQuery(con, 'select probes.key from probes') $key
## benchmark
n = 50
system.time( sapply(sample(myprobes, n), function(x){ qh(x) }) )
system.time( sapply(sample(myprobes, n), function(x){ qhleft(x) }) )
system.time( sapply(sample(myprobes, n), function(x){ qdplyr2(x) }) )


## test for variance in single queries

n = 50
sapply(1:n, function(x){print(system.time(qh( sample(myprobes, 1) ) ) ) } )
elapsed = sapply(1:n, function(x){print(system.time(qdplyr2( sample(myprobes, 3) ))["elapsed"] )})
summary(elapsed)


n = 10
nprobes = 1
##print('sqlite')
##system.time( sapply(1:n, function(x){ qh( sample(myprobes, nprobes), conn = con2 ) } ) )
print('mysql')
system.time( sapply(1:n, function(x){ qh( sample(myprobes, nprobes) ) } ) )


system.time( sapply(1:n, function(x){ qhleft( sample(myprobes, nprobes) ) } ) )
system.time( sapply(1:n, function(x){ qdplyr2( sample(myprobes, nprobes) ) } ) )

system.time( sapply(1:n, function(x){ qtcgai( sample(indexi, nprobes) ) } ) )

dbGetQuery(con, 'show profile')


##system.time( sapply(sample(myprobes, n), function(x){ qdplyr(x) }) )
##system.time( sapply(sample(myprobes, n), function(x){ qdplyr2(x) }) )
##system.time( sapply(sample(myprobes, n), function(x){ qh(x) }) )



##system.time( sapply(sample(myprobes, n), function(x){ qnh(x) }) )
##system.time( sapply(sample(myprobes, n), function(x){ qv(x) }) )


sapply(myprobes, function(x){ print(x); print(head(qh(x))) })

dbClearResult(dbListResults(con)[[1]])

dbListResults(con)


