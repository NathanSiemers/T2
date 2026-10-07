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
    WHEN COALESCE(sp.sparse, 1) = 1 THEN COALESCE(sp.default_value, 0)
    ELSE NULL
  END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
LEFT JOIN sparse sp ON sp.type = pt.type
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
    WHEN COALESCE(sp.sparse, 1) = 1 THEN COALESCE(sp.default_value, 0)
    ELSE NULL
  END AS value,
  pt.type
FROM probes pr
JOIN probe_types pt ON pt.probekey = pr.key
JOIN tested t ON t.type = pt.type
LEFT JOIN sparse sp ON sp.type = pt.type
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
## bytype: every numeric value of ONE DATA TYPE with names, or of one probe:
##     SELECT probe, sample, value FROM bytype WHERE type = 'rppa'
##     SELECT probe, sample, value FROM bytype WHERE probe = 'CD8A'
## Starts from probe_types (type -> its probes; CROSS JOIN pins that order) so
## that each probe's rows are one contiguous read of the covering index: rppa
## (2 M rows) in 2 s, all of rna (195 M rows) in ~150 s, with no type-only index
## on tcgai. A bare `SELECT ... FROM tcgai WHERE type = X` scans the whole table.

dbExecute(con, 'DROP VIEW IF EXISTS bytype')
dbExecute(con, "
CREATE VIEW bytype AS
SELECT pt.type, pr.probe, sa.sample, d.value, d.probekey, d.samplekey
FROM probe_types pt
CROSS JOIN tcgai d ON d.probekey = pt.probekey AND d.type = pt.type
JOIN probes pr ON pr.key = pt.probekey
JOIN samples sa ON sa.key = d.samplekey
")
print("created view: bytype (all values of one type, or of one probe, through probe_types)")

################################################################
## mutationsamples: exome-sequenced samples (derived from mutation table)

dbExecute(con, 'DROP VIEW IF EXISTS mutationsamples')
dbExecute(con, 'DROP TABLE IF EXISTS mutationsamples')
dbExecute(con, 'CREATE VIEW mutationsamples AS SELECT DISTINCT sample FROM mutation')
print("created view: mutationsamples")
