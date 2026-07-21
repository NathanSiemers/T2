## Final indexes on the main data tables
## Uses IF NOT EXISTS so this script is safe to run multiple times

if(mysql) {
    try(dbExecute(con, 'drop index tcgaidx_pt on tcgai'), silent = TRUE)
    dbExecute(con, 'create index tcgaidx_pt on tcgai(probekey, type) using hash')
} else {
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgaiidx_pts ON tcgai(probekey, type, samplekey)')
    ## type-leading index on the CATEGORICAL fact table. Without it, filtering a
    ## categorical view by type (e.g. SELECT * FROM tcgacat WHERE type="fmut")
    ## full-scans tcgacati, because tcgacatiidx_pts leads with probekey. Leading
    ## with type turns that SCAN into an indexed range SEARCH (~15x faster on a
    ## selective type). The NUMERIC views are already type-fast via probe_types
    ## (probe_types_tp) + tested (tested_type_sample), so tcgai needs nothing
    ## beyond typeidx from 050-create_early_indexes.R.
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgacatiidx_tsp ON tcgacati(type, samplekey, probekey)')
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tested_type ON tested(type)')
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS tested_type_sample ON tested(type, sample)')
    ## speeds up tumtype filters on tcga/tcgacat views (e.g. WHERE tumtype = "STAD")
    dbExecute(con, 'CREATE INDEX IF NOT EXISTS clinpheno_tumtype_sample ON clinpheno(tumtype, sample)')
    ## Serve in WAL journal mode: read-only app connections never block an
    ## external writer (e.g. adding an index) and vice-versa. WAL is a
    ## persistent property of the db file, so setting it once here is enough.
    dbExecute(con, 'PRAGMA journal_mode=WAL')
}
