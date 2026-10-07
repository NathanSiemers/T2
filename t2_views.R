## t2_views.R
## ============================================================================
## REUSABLE "core shape" DDL for a T2 dataset db: the probe_types lookup, the
## four dense/categorical views (tcgas / tcgacats / tcga / tcgacat) and the
## performance indexes. One source of truth so every dataset builder agrees on
## the exact view shape the app/gitr expect (see MULTIDATASET.md).
##
## The full tcga.db pipeline keeps its own copy of this DDL in
## 250-create_views.R because it ALSO builds TCGA-only objects (the
## mutationsamples view over a `mutation` table). New, simpler datasets
## (build_demo_dataset.R, TCGATARGETGTEX/build_tcgatargetgtex.R) source THIS
## file instead of re-pasting the DDL.
##
## All helpers take an open DBI connection `con`.
## ============================================================================

## probe_types: DISTINCT (probekey, type) over the NUMERIC fact table only.
## Categorical (tcgacati-only) probes must NOT appear here, otherwise the dense
## numeric tcgas view would surface them with the CASE-ELSE-0 default and gitr
## would never fall through to the categorical tcgacats view.
build_t2_probe_types <- function(con) {
  DBI::dbExecute(con, "DROP TABLE IF EXISTS probe_types")
  DBI::dbExecute(con, "CREATE TABLE probe_types AS SELECT DISTINCT probekey, type FROM tcgai")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS probe_types_cat")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS sparse_cat_types")
}

create_t2_core_indexes <- function(con) {
  idx <- c(
    "CREATE INDEX IF NOT EXISTS probe_types_pk  ON probe_types(probekey, type)",
    "CREATE INDEX IF NOT EXISTS probe_types_tp  ON probe_types(type, probekey)",
    ## COVERING indexes: `value` is in the index, so every value of one probe is
    ## ONE contiguous index read. Without it each of a probe's ~11,000 values is
    ## its own scattered table-row read (1-2 s for a gene nobody has asked for
    ## yet, in gitr() and in the t2api service alike).
    "CREATE INDEX IF NOT EXISTS tcgaiidx_pts    ON tcgai(probekey, type, samplekey, value)",
    "CREATE INDEX IF NOT EXISTS tcgacatiidx_pts ON tcgacati(probekey, type, samplekey, value)",
    ## type-leading index so `... WHERE type = X` on the categorical views is an
    ## indexed SEARCH, not a full SCAN of tcgacati (~15x on a selective type).
    "CREATE INDEX IF NOT EXISTS tcgacatiidx_tsp ON tcgacati(type, samplekey, probekey)",
    "CREATE INDEX IF NOT EXISTS tested_type        ON tested(type)",
    "CREATE INDEX IF NOT EXISTS tested_type_sample ON tested(type, sample)",
    "CREATE INDEX IF NOT EXISTS clinphenoidx     ON clinpheno(sample)",
    "CREATE INDEX IF NOT EXISTS samplesidx       ON samples(sample)",
    "CREATE INDEX IF NOT EXISTS probesidx        ON probes(probe)"
  )
  for (s in idx) DBI::dbExecute(con, s)
}

## The `sparse` table: one row per data type saying how it was loaded.
##   sparse = 1  zero values are not stored: a sample TESTED for the type with no
##               row for a probe has default_value (0)
##   sparse = 0  every value is stored: no row means missing (NA)
## A stored NULL is NA either way, and a sample not in `tested` for the type is
## NA either way. The TCGA pipeline fills this table in tablemaker(); the other
## builders call set_t2_sparse(). A type with no row is treated as sparse with
## default 0 (how every database built before October 2026 behaves).
create_t2_sparse_table <- function(con) {
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS sparse (type varchar(35) PRIMARY KEY, sparse int NOT NULL, default_value double)")
}
set_t2_sparse <- function(con, type, sparse = TRUE, default_value = 0) {
  create_t2_sparse_table(con)
  DBI::dbExecute(con, "DELETE FROM sparse WHERE type = ?", params = list(type))
  DBI::dbExecute(con, "INSERT INTO sparse (type, sparse, default_value) VALUES (?, ?, ?)",
                 params = list(type, as.integer(isTRUE(sparse)), if (isTRUE(sparse)) default_value else NA_real_))
}

create_t2_core_views <- function(con) {
  create_t2_sparse_table(con)
  ## tcgas: dense numeric. For a sample tested for the probe's type: the stored
  ## value (a stored NULL stays NULL = NA); with no stored row, the type's default
  ## (0) if the type is sparse, else NULL. Untested samples are not in the view.
  DBI::dbExecute(con, "DROP VIEW IF EXISTS tcgas")
  DBI::dbExecute(con, "
CREATE VIEW tcgas AS
SELECT sa.sample, pr.probe,
  CASE WHEN dat.probekey IS NOT NULL THEN dat.value
       WHEN COALESCE(sp.sparse, 1) = 1 THEN COALESCE(sp.default_value, 0)
       ELSE NULL END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
LEFT JOIN sparse sp ON sp.type = pt.type
JOIN samples sa ON sa.sample = t.sample
LEFT JOIN tcgai dat ON dat.probekey = pr.key AND dat.samplekey = sa.key AND dat.type = pt.type")

  ## bytype: every numeric value of ONE DATA TYPE with names, or of one probe:
  ##     SELECT probe, sample, value FROM bytype WHERE type = 'rppa'
  ##     SELECT probe, sample, value FROM bytype WHERE probe = 'CD8A'
  ## Starts from probe_types (type -> its probes; CROSS JOIN pins that order) so
  ## that each probe's rows are one contiguous read of the covering index: rppa
  ## (2 M rows) in 2 s, all of rna (195 M rows) in ~150 s, with no type-only index
  ## on tcgai. A bare `SELECT ... FROM tcgai WHERE type = X` scans the whole table.
  DBI::dbExecute(con, "DROP VIEW IF EXISTS bytype")
  DBI::dbExecute(con, "
CREATE VIEW bytype AS
SELECT pt.type, pr.probe, sa.sample, d.value, d.probekey, d.samplekey
FROM probe_types pt
CROSS JOIN tcgai d ON d.probekey = pt.probekey AND d.type = pt.type
JOIN probes pr ON pr.key = pt.probekey
JOIN samples sa ON sa.key = d.samplekey")

  ## tcgacats: simple categorical (absent = NA at the R level via gitr join)
  DBI::dbExecute(con, "DROP VIEW IF EXISTS tcgacats")
  DBI::dbExecute(con, "
CREATE VIEW tcgacats AS
SELECT sa.sample, pr.probe, dat.value, dat.type
FROM tcgacati dat
JOIN samples sa ON sa.key = dat.samplekey
JOIN probes pr ON pr.key = dat.probekey")

  ## tcga: dense numeric + clinpheno
  DBI::dbExecute(con, "DROP VIEW IF EXISTS tcga")
  DBI::dbExecute(con, "
CREATE VIEW tcga AS
SELECT cp.*, pr.probe,
  CASE WHEN dat.probekey IS NOT NULL THEN dat.value
       WHEN COALESCE(sp.sparse, 1) = 1 THEN COALESCE(sp.default_value, 0)
       ELSE NULL END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
LEFT JOIN sparse sp ON sp.type = pt.type
JOIN samples sa ON sa.sample = t.sample
JOIN clinpheno cp ON cp.sample = sa.sample
LEFT JOIN tcgai dat ON dat.probekey = pr.key AND dat.samplekey = sa.key AND dat.type = pt.type")

  ## tcgacat: simple categorical + clinpheno
  DBI::dbExecute(con, "DROP VIEW IF EXISTS tcgacat")
  DBI::dbExecute(con, "
CREATE VIEW tcgacat AS
SELECT cp.*, pr.probe, dat.value, dat.type
FROM tcgacati dat
JOIN samples sa ON sa.key = dat.samplekey
JOIN probes pr ON pr.key = dat.probekey
JOIN clinpheno cp ON cp.sample = sa.sample")
}

## Convenience: probe_types + indexes + views, in the right order.
finalize_t2_core <- function(con) {
  build_t2_probe_types(con)
  create_t2_core_indexes(con)
  create_t2_core_views(con)
  ## Serve in rollback-journal mode: the db is built elsewhere and copied into
  ## place, never written while served, and read by read-only containers that
  ## can't create -wal/-shm files. Persistent property of the db file.
  DBI::dbExecute(con, "PRAGMA journal_mode=DELETE")
}
