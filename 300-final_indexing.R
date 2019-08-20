
if(mysql) {
    ## tcgai (probekey, type)
    try(dbExecute(  con, 'drop index tcgaidx_pt on tcgai'), silent = TRUE)
    dbExecute(  con, 'create index tcgaidx_pt on tcgai( probekey, type ) using hash')
    ## ## tcgai ( type )
    ## try(dbExecute(  con, 'drop index tcgaidx_t on tcgai'), silent = TRUE)
    ## dbExecute(  con, 'create index tcgaidx_t on tcgai( type, samplekey ) using hash')
    ## ## tcgacati (probekey, type)
    ## try(dbExecute(  con, 'drop index tcgacatidx_t on tcgacati'), silent = TRUE)
    ## dbExecute(  con, 'create index tcgacatidx_t on tcgacati( type, samplekey ) using hash')
} else {
    ## tcgai (probekey, type)
    try(dbExecute(  con, 'drop index tcgaidx_pt'), silent = TRUE)
    dbExecute(  con, 'create index tcgaidx_pt on tcgai ( probekey, type )')
    ## tcgai (type)
    ## try(dbExecute(  con, 'drop index tcgaidx_t'), silent = TRUE)
    ## dbExecute(  con, 'create index tcgaidx_t on tcgai ( type, samplekey )')
    ## ## tcgacati (probekey, type)
    ## try(dbExecute(  con, 'drop index tcgacatidx_t'), silent = TRUE)
    ## dbExecute(  con, 'create index tcgacatidx_t on tcgacati ( type, samplekey )')
}
