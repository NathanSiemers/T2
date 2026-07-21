library(tidyverse)
source('../gitr.R')
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

dim(sig_load)
sig_load = sig_load[ !is.na(sig_load$value), ]
dim(sig_load)


tablemaker(dat = sig_load, connection = con, deleteType = TRUE,  suffix = FALSE)

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
