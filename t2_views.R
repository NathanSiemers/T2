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
    "CREATE INDEX IF NOT EXISTS tcgaiidx_pts    ON tcgai(probekey, type, samplekey)",
    "CREATE INDEX IF NOT EXISTS tcgacatiidx_pts ON tcgacati(probekey, type, samplekey)",
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

create_t2_core_views <- function(con) {
  ## tcgas: dense numeric (tested + probe_types -> sparse 0 vs NULL NA)
  DBI::dbExecute(con, "DROP VIEW IF EXISTS tcgas")
  DBI::dbExecute(con, "
CREATE VIEW tcgas AS
SELECT sa.sample, pr.probe,
  CASE WHEN dat.probekey IS NOT NULL THEN dat.value ELSE 0 END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
LEFT JOIN tcgai dat ON dat.probekey = pr.key AND dat.samplekey = sa.key AND dat.type = pt.type")

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
  CASE WHEN dat.probekey IS NOT NULL THEN dat.value ELSE 0 END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
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
  ## Serve in WAL mode so read-only app connections never block an external
  ## writer (and vice-versa). Persistent property of the db file.
  DBI::dbExecute(con, "PRAGMA journal_mode=WAL")
}
