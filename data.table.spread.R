library(data.table)
library(tidyverse)
tcgai = tbl(con, "tcgai"); samples = tbl(con, "samples"); probes = tbl(con, "probes")

Sys.time()
n = 10000000
d = setDT( tcgai %>% head(n) %>%
    left_join( samples %>% rename(samplekey = key) ) %>%
        left_join( probes %>% rename(probekey = key) ) %>%
            select(sample, probe, value)  %>% collect )
Sys.time()
s = dcast(d, sample ~ probe, value.var = "value")
dim(s)
Sys.time()
