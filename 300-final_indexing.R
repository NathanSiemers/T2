## Final indexes on the main data tables
## Uses IF NOT EXISTS so this script is safe to run multiple times

if(mysql) {
    try(dbExecute(con, 'drop index tcgaidx_pt on tcgai'), silent = TRUE)
    dbExecute(con, 'create index tcgaidx_pt on tcgai(probekey, type) using hash')
} else {
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgaiidx_pts ON tcgai(probekey, type, samplekey)')
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tested_type ON tested(type)')
}
