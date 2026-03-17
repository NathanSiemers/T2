# T2 - a TCGA database and shiny tool for the 2018 release of TCGA Pan-Cancer studies

Nathan Siemers

## Getting started

00-master.R is the master R script that builds the database.  It will
wipe out the old database if all subcomponents are run.

The active branch to work on is 'mysql', the other branch is not being
updated.  As implied, this was the branch that ported the system to
accomodate mysql in addition to sqlite relational databases.

The build scripts are now organized mostly around the idea that each
data type gets a build file.

The repetitive database connection calls in 00-master are likely not
needed, only intended to ensure that database connection doesn't drop.



