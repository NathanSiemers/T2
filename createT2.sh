#

rsync -av --exclude '.domino*' --exclude Data --exclude tcga.db ../T2/ ../T2Create

chmod 0775 *.sh

./runBatch.sh







