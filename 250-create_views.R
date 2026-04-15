################################################################
## Create views
##
## tcgas/tcga: dense numeric views using tested table + probe_types
##   to distinguish 0 (tested, sparse zero) from NA (untested)
##
## tcgacats/tcgacat: simple categorical views (denormalized tcgacati)
##   absent = NA at the R level via left_join in gitr

################################################################
## probe_types lookup table for numeric views

print("creating probe_types lookup table from tcgai")
dbExecute(con, 'DROP TABLE IF EXISTS probe_types')
dbExecute(con, 'CREATE TABLE probe_types AS SELECT DISTINCT probekey, type FROM tcgai')
dbExecute(con, 'CREATE INDEX probe_types_pk ON probe_types(probekey, type)')
dbExecute(con, 'CREATE INDEX probe_types_tp ON probe_types(type, probekey)')

## probe_types_cat no longer needed — tcgacats is a simple denormalized view
dbExecute(con, 'DROP TABLE IF EXISTS probe_types_cat')
dbExecute(con, 'DROP TABLE IF EXISTS sparse_cat_types')

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
## tcgacats: simple categorical view (denormalized tcgacati)
## No cross-join needed: absent = NA at the R level via left_join

dbExecute(con, 'DROP VIEW IF EXISTS tcgacats')
dbExecute(con, '
CREATE VIEW tcgacats AS
SELECT
  sa.sample,
  pr.probe,
  dat.value,
  dat.type
FROM tcgacati dat
JOIN samples sa ON sa.key = dat.samplekey
JOIN probes pr ON pr.key = dat.probekey
')
print("created view: tcgacats (simple categorical)")

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
## tcgacat: simple categorical + clinpheno join

dbExecute(con, 'DROP VIEW IF EXISTS tcgacat')
dbExecute(con, '
CREATE VIEW tcgacat AS
SELECT
  cp.*,
  pr.probe,
  dat.value,
  dat.type
FROM tcgacati dat
JOIN samples sa ON sa.key = dat.samplekey
JOIN probes pr ON pr.key = dat.probekey
JOIN clinpheno cp ON cp.sample = sa.sample
')
print("created view: tcgacat (simple categorical + clinpheno)")

################################################################
## mutationsamples: exome-sequenced samples (derived from mutation table)

dbExecute(con, 'DROP VIEW IF EXISTS mutationsamples')
dbExecute(con, 'DROP TABLE IF EXISTS mutationsamples')
dbExecute(con, 'CREATE VIEW mutationsamples AS SELECT DISTINCT sample FROM mutation')
print("created view: mutationsamples")
