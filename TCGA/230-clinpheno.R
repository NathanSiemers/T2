
phenos  = dbGetQuery(con, '
select samples.sample, probes.probe, tcgacati.value from tcgacati, probes, samples
where tcgacati.probekey = probes.key
and tcgacati.samplekey = samples.key
and tcgacati.type <> "fmut"
')
str(phenos)
tail(phenos)
table(phenos$value)
table(phenos$Subtype_Selected)
 

phenos = phenos %>% distinct(sample, probe, .keep_all = TRUE) %>% spread(probe, value)
unique(phenos$'_primary_disease')
tail(phenos)
which(duplicated(phenos$sample))
dbWriteTable(con, 'tmptable', phenos, overwrite = TRUE, row.names = FALSE)
clinpheno_intermediate = dbGetQuery(con, '
select * from clin
left join tmptable
on clin.sample = tmptable.sample
')

print(table(clinpheno_intermediate$Subtype_Selected))

## Remove duplicate columns (maybe none)
clinpheno_intermediate = clinpheno_intermediate[ , ! duplicated(colnames(clinpheno_intermediate)) ]

## Create short-name subtype columns from the suffixed versions
## and fill NA values with tumtype.NA
subtype_map = list(
    Subtype_Selected         = "Subtype_Selected.molec_subtype",
    Subtype_CNA              = "Subtype_CNA.molec_subtype",
    Subtype_DNAmeth          = "Subtype_DNAmeth.molec_subtype",
    Subtype_Immune_Model_Based = "Subtype_Immune_Model_Based.immune_subtype",
    Subtype_Integrative      = "Subtype_Integrative.molec_subtype",
    Subtype_miRNA            = "Subtype_miRNA.molec_subtype",
    Subtype_mRNA             = "Subtype_mRNA.molec_subtype",
    Subtype_other            = "Subtype_other.molec_subtype",
    Subtype_protein          = "Subtype_protein.molec_subtype"
)
for (short in names(subtype_map)) {
    long = subtype_map[[short]]
    if (long %in% colnames(clinpheno_intermediate)) {
        clinpheno_intermediate[[short]] = clinpheno_intermediate[[long]]
    }
    na_rows = is.na(clinpheno_intermediate[[short]])
    clinpheno_intermediate[na_rows, short] =
        paste(clinpheno_intermediate[na_rows, "tumtype"], "NA", sep = '.')
}

print(as.data.frame(table(clinpheno_intermediate$Subtype_Selected), exclude = NULL))

try(dbRemoveTable(con, 'clinpheno'), silent = TRUE)
dbWriteTable(con, 'clinpheno', clinpheno_intermediate, row.names = FALSE, overwrite = TRUE)
dbGetQuery(con, 'select distinct Subtype_Selected from clinpheno')


if( mysql ) {
    try(dbExecute( con, 'drop index clinphenoidx on clinpheno') , silent = TRUE)
} else {
    dbExecute( con, 'drop index if exists clinphenoidx')
}

if(mysql) {
    dbExecute( con, 'alter table clinpheno modify sample varchar(35)' )
}

dbExecute( con, 'create index clinphenoidx on clinpheno(sample)' )

str(dbGetQuery(con, 'select * from clinpheno limit 5'))
