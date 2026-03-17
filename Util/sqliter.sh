#

sqlite3 -batch tcga.db 'create table methyl (sample int, variable int, value numeric);'

cat jhu-usc.edu_PANCAN_HumanMethylation450.betaValue_whitelisted.tsv.synapse_download_5096262.xena.gz |\
    gunzip |\
    perl tidyint.pl |\
    cat <(echo -e ".separator ','\n.import /dev/stdin methyl") - | sqlite3 tcga.db



#cat methyl.csv.gz | gunzip | cat <(echo -e ".separator ','\n.import /dev/stdin methyl") - | sqlite3 tcga.db

##  UPDATE MyTable SET MyColumn = CAST(MyColumn AS INTEGER)
