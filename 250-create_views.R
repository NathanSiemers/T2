################################################################
## create dense views
## these views handle sparse data correctly:
##   - tested sample with no row in tcgai → 0 (sparse zero)
##   - tested sample with NULL in tcgai   → NA (genuine missing)
##   - untested sample                    → not returned (true NA at caller level)
##
## requires: probe_types and probe_types_cat lookup tables
## requires: tcgaiidx_pts index on tcgai(probekey, type, samplekey)
## requires: tcgacatiidx_pts index on tcgacati(probekey, type, samplekey)

################################################################
## build probe_types lookup tables (small, ~100K rows)
## these map each probekey to its type(s) in tcgai/tcgacati

print("creating probe_types lookup table from tcgai")
dbExecute(con, 'DROP TABLE IF EXISTS probe_types')
dbExecute(con, 'CREATE TABLE probe_types AS SELECT DISTINCT probekey, type FROM tcgai')
dbExecute(con, 'CREATE INDEX probe_types_pk ON probe_types(probekey, type)')
dbExecute(con, 'CREATE INDEX probe_types_tp ON probe_types(type, probekey)')

print("creating probe_types_cat lookup table from tcgacati")
## exclude high-cardinality types (fmut: 21K probes × 9K samples = 194M view rows)
## these are queried directly from tcgacati via gitr's sparse fallback
dbExecute(con, 'DROP TABLE IF EXISTS probe_types_cat')
dbExecute(con, 'CREATE TABLE probe_types_cat AS
  SELECT DISTINCT probekey, type FROM tcgacati WHERE type <> "fmut"')
dbExecute(con, 'CREATE INDEX probe_types_cat_pk ON probe_types_cat(probekey, type)')
## keep a list of sparse categorical types for gitr's fallback
dbExecute(con, 'DROP TABLE IF EXISTS sparse_cat_types')
dbExecute(con, 'CREATE TABLE sparse_cat_types AS
  SELECT DISTINCT type FROM tcgacati WHERE type NOT IN (SELECT DISTINCT type FROM probe_types_cat)')
print("sparse categorical types (excluded from dense view):")
print(dbGetQuery(con, 'SELECT * FROM sparse_cat_types'))

## index on tcgacati if not already present
try(dbExecute(con, 'CREATE INDEX IF NOT EXISTS tcgacatiidx_pts ON tcgacati(probekey, type, samplekey)'), silent = TRUE)

################################################################
## tcgas: dense numeric view (sample, probe, value, type)

dbExecute(con, 'DROP VIEW IF EXISTS tcgas')
dbExecute(con, '
CREATE VIEW tcgas AS
SELECT
  sa.sample,
  pr.probe,
  CASE
    WHEN dat.probekey IS NOT NULL THEN dat.value
    ELSE 0
  END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
LEFT JOIN tcgai dat
  ON dat.probekey   = pr.key
  AND dat.samplekey = sa.key
  AND dat.type      = pt.type
')
print("created view: tcgas (dense numeric)")

################################################################
## tcgacats: dense categorical view (sample, probe, value, type)

dbExecute(con, 'DROP VIEW IF EXISTS tcgacats')
dbExecute(con, '
CREATE VIEW tcgacats AS
SELECT
  sa.sample,
  pr.probe,
  dat.value,
  pt.type
FROM probes pr
JOIN probe_types_cat pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
LEFT JOIN tcgacati dat
  ON dat.probekey   = pr.key
  AND dat.samplekey = sa.key
  AND dat.type      = pt.type
')
print("created view: tcgacats (dense categorical)")

################################################################
## tcga: dense numeric + clinpheno join

dbExecute(con, 'DROP VIEW IF EXISTS tcga')
dbExecute(con, '
CREATE VIEW tcga AS
SELECT
  cp.*,
  pr.probe,
  CASE
    WHEN dat.probekey IS NOT NULL THEN dat.value
    ELSE 0
  END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
JOIN clinpheno cp ON cp.sample = sa.sample
LEFT JOIN tcgai dat
  ON dat.probekey   = pr.key
  AND dat.samplekey = sa.key
  AND dat.type      = pt.type
')
print("created view: tcga (dense numeric + clinpheno)")

################################################################
## tcgacat: dense categorical + clinpheno join

dbExecute(con, 'DROP VIEW IF EXISTS tcgacat')
dbExecute(con, '
CREATE VIEW tcgacat AS
SELECT
  cp.*,
  pr.probe,
  dat.value,
  pt.type
FROM probes pr
JOIN probe_types_cat pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
JOIN samples sa ON sa.sample = t.sample
JOIN clinpheno cp ON cp.sample = sa.sample
LEFT JOIN tcgacati dat
  ON dat.probekey   = pr.key
  AND dat.samplekey = sa.key
  AND dat.type      = pt.type
')
print("created view: tcgacat (dense categorical + clinpheno)")
