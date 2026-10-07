################################################################
## it **might** be good to add some indexes early on...
## this will slow down register of new probes and samples
## but should make the big tidy load faster?

dbExecute( con, 'create index probesidx on probes ( probe )')
dbExecute( con, 'create index samplesidx on samples ( sample )')
## No type-only index on tcgai: it was 8.6 GB (a fifth of the file) and nothing the apps
## run used it; "all rows of one type" goes through probe_types and the covering index
## (view `bytype`, as fast or faster -- measured 2026-10-07 with Util/index_bench.py).
## tablemaker() therefore only deletes a type's old rows when the type was loaded before.
