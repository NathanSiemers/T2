################################################################
## create views
## you can create the views before any tables have data
## or seemingly even before tables exist? (clinpheno)
## this doesn't work for mysql so view creation must happen later...

################################################################
## simple tidy tcga numeric data view

if(mysql){
    dbExecute( con, 'drop view if exists tcgas')
    ## works for sqlite
    dbExecute(con, '
create view tcgas as
select samples.sample, probes.probe, tcgai.value, tcgai.type
from tcgai, samples, probes
where tcgai.samplekey = samples.key and
tcgai.probekey = probes.key
')
} else {
    dbExecute( con, 'drop view if exists tcgas')
    ## works for sqlite
    dbExecute(con, '
create view tcgas as
select samples.sample, probes.probe, tcgai.value, tcgai.type
from tcgai, samples, probes
where tcgai.samplekey = samples.key and
tcgai.probekey = probes.key
')
}



################################################################
## simple tidy tcga categorical data view

if(mysql){
    dbExecute( con, 'drop view if exists tcgacats')
    ## works for sqlite
    dbExecute(con, '
create view tcgacats as
select samples.sample, probes.probe, tcgacati.value, tcgacati.type
from tcgacati, samples, probes
where tcgacati.samplekey = samples.key and
tcgacati.probekey = probes.key
')
} else {
    dbExecute( con, 'drop view if exists tcgacats')
    ## works for sqlite
    dbExecute(con, '
create view tcgacats as
select samples.sample, probes.probe, tcgacati.value, tcgacati.type
from tcgacati, samples, probes
where tcgacati.samplekey = samples.key and
tcgacati.probekey = probes.key
')
}


## dbExecute( con, 'drop view if exists tcgacats' )
## dbExecute(con, '
## create view tcgacats as
## select samples.sample, probes.probe, tcgacati.value, tcgacati.type
## from tcgacati, samples, probes
## where tcgacati.samplekey = samples.key and
## tcgacati.probekey = probes.key
## ')

################################################################
## main TCGA view
## join untidy (wide) clinical info
## plus tidy numeric genomic data in probe and value columns

dbExecute( con, 'drop view if exists tcga')
dbExecute(con, '
create view tcga as
select clinpheno.*, probe, value, type
from tcgai, samples, probes, clinpheno
where tcgai.samplekey = samples.key 
and tcgai.probekey = probes.key
and samples.sample = clinpheno.sample
' )

dbExecute(con, '
create view testy as
select clinpheno.*, probe, value, type
from tcgai, samples, probes, clinpheno
where tcgai.samplekey = samples.key 
and tcgai.probekey = probes.key
and samples.sample = clinpheno.sample
' )

################################################################
## main TCGA view for categorical data
## cluster/subtype assignments, etc

dbExecute( con, 'drop view if exists tcgacat' )
dbExecute( con, '
create view tcgacat as
select clinpheno.*, probe, value, type
from tcgacati, samples, probes, clinpheno
where tcgacati.samplekey = samples.key 
and tcgacati.probekey = probes.key
and samples.sample = clinpheno.sample
' )



