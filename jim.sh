#!/bin/sh

R --version

## want to see the output log live (I hope)

##exec nohup R --no-save --no-restore CMD BATCH 00-master.R

##R --no-save --no-restore CMD BATCH 00-master.R
Rscript jim.sh

##    | tee runBatch.log




