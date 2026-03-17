################################################################
## it **might** be good to add some indexes early on...
## this will slow down register of new probes and samples
## but should make the big tidy load faster?

dbExecute( con, 'create index probesidx on probes ( probe )')
dbExecute( con, 'create index samplesidx on samples ( sample )')
dbExecute( con, 'create index typeidx on tcgai ( type )')
