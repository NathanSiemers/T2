library(tidyverse)
library(sqldf)
source('signatures.R')
source('apply_signatures.R')
source('tablemaker.R')
source('lib.R')

db = 'tcga.db'
con <- DBI::dbConnect(RSQLite::SQLite(), dbname = db, flags = SQLITE_RO )
tcga = tbl(con, 'tcga')
tcgacat = tbl(con, 'tcgacat')

if(FALSE){ #testing

dsl$TCD8.sig$comp
test = sig_fn(dat = tcga, dsl$TCD8.sig$comp, gitr = TRUE) %>% head
dim(test)
test
test2 = create_signatures(dat = tcga, siglist = dsl[1:3])
head(test2)
## does NK.sig work?
test3 = create_signatures(dat = tcga, siglist = dsl["NK.sig"] )
head(test3)
## YES!
## now harder
test4 = create_signatures(dat = tcga, siglist = dsl["TregCD8.sig"] )
head(test4)
test5 = create_signatures(dat = tcga, siglist = dsl["NKCD8.sig"] )
head(test5)

}

sig_projection = create_signatures(dat = tcga, siglist = dsl)
dim(sig_projection)
head(sig_projection, 1)

sig_load = sig_projection %>%
    gather(probe, value, -sample) %>%
        mutate(type = 'sig') %>%
            select( sample, probe, value, type )
tablemaker(data = sig_load, db = db, deleteType = TRUE, suffix = FALSE)
system('touch restart.txt')



