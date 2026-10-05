library(tidyverse)
source('../gitr.R')
## Point gitr at the db being built. gitr connects to `gitrdb` (default
## 'tcga.db') and queries the tcgas/tcgacats views, which exist by this step.
## From the TCGA/ working directory 'tcga.db' would not resolve — use the same
## db path the rest of the build uses.
gitrdb = Sys.getenv('TCGA_DB', '../tcga.db')
source('signatures.R')
source('apply_signatures.R')
source('tablemaker.R')

tcga = tbl(con, 'tcga')
tcgacat = tbl(con, 'tcgacat')

sig_projection = create_signatures(dat = tcga, siglist = dsl)
dim(sig_projection)
head(sig_projection, 5)
length(which(is.na(sig_projection)))

sig_load = sig_projection %>%
    gather(probe, value, -sample) %>%
        mutate(type = 'sig') %>%
            select( sample, probe, value, type ) %>%
                mutate(oprobe = probe) %>%
                    as_tibble
length(which(is.na(sig_load$value)))
head(sig_load)

my_na = sig_load[is.na(sig_load$value), ]
table(my_na$probe)  ## always  the same number per sig no matter what!
head(my_na)
length(unique(my_na$sample))  # they are all the same samples

## Signatures are loaded in full (sparse = FALSE): every value is stored, a
## missing signature (a sample without all of the members, e.g. no RNA data) is
## stored as NULL, and nothing is ever inferred to be 0.
dim(sig_load)
table(is.na(sig_load$value))

tablemaker(dat = sig_load, connection = con, deleteType = TRUE,  suffix = FALSE, sparse = FALSE)

system('touch restart.txt')

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
