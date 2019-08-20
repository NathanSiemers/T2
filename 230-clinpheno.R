
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

## Remove duplicate columns (maybe none) and replace subtype NA values with tumtype.NA
clinpheno_intermediate = clinpheno_intermediate[ , ! duplicated(colnames(clinpheno_intermediate)) ]
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Selected), "Subtype_Selected" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Selected), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_CNA), "Subtype_CNA" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_CNA), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_DNAmeth), "Subtype_DNAmeth" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_DNAmeth), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Immune_Model_Based), "Subtype_Immune_Model_Based" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Immune_Model_Based), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Integrative), "Subtype_Integrative" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_Integrative), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_miRNA), "Subtype_miRNA" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_miRNA), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_mRNA), "Subtype_mRNA" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_mRNA), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_other), "Subtype_other" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_other), "tumtype" ], "NA", sep = '.' )
clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_protein), "Subtype_protein" ]   =
    paste( clinpheno_intermediate[ is.na(clinpheno_intermediate$Subtype_protein), "tumtype" ], "NA", sep = '.' )

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
