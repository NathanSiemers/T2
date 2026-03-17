## need to write a separate file that only destroys...
sqldestroy = FALSE   # delete datbases before starting!
TESTING = TRUE
TESTINGLINES = Inf
mysql  = FALSE
mysqldb = 'prod'    # dev or prod
download = TRUE
sqlvacuum = FALSE
optimize = FALSE
xena.force = FALSE
Sys.setenv("VROOM_CONNECTION_SIZE" = 1e9)  # read_tsv seems to be calling vroom and barfing.  wtf.
