## Final indexes on the main data tables
## Uses IF NOT EXISTS so this script is safe to run multiple times

if(mysql) {
    try(dbExecute(con, 'drop index tcgaidx_pt on tcgai'), silent = TRUE)
    dbExecute(con, 'create index tcgaidx_pt on tcgai(probekey, type) using hash')
} else {
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgaiidx_pts ON tcgai(probekey, type, samplekey)')
    ## The CATEGORICAL fact table needs BOTH indexes (matches t2_views.R):
    ##  - probekey-leading: gitr looks up categorical data BY PROBE via the
    ##    tcgacats view (mutations, molecular/immune subtypes). Without it that
    ##    query full-scans tcgacati.
    ##  - type-leading: `... WHERE type = X` on the categorical views becomes an
    ##    indexed SEARCH not a full SCAN (~15x on a selective type).
    ## (The NUMERIC views are already type-fast via probe_types + tested, so
    ##  tcgai needs nothing beyond typeidx from 050-create_early_indexes.R.)
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgacatiidx_pts ON tcgacati(probekey, type, samplekey)')
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgacatiidx_tsp ON tcgacati(type, samplekey, probekey)')
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tested_type ON tested(type)')
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tested_type_sample ON tested(type, sample)')
    ## speeds up tumtype filters on tcga/tcgacat views (e.g. WHERE tumtype = "STAD")
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS clinpheno_tumtype_sample ON clinpheno(tumtype, sample)')
    ## WAL while building (faster writes, readers never block the builder).
    ## promote_db() in 00-master.R switches the finished db back to
    ## rollback-journal mode for serving (single file, no -wal/-shm).
    dbExecute(con, 'PRAGMA journal_mode=WAL')
}
