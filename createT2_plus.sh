#!/bin/bash

rsync -av --exclude '.domino*' --exclude Data --exclude tcga.db ../T2/ ../T2Create

chmod 0775 *.sh

./runBatch_plus_vacuum.sh


if [[ -z "${DOMINO_RUN_NUMBER}" ]]; then
    echo not on domino
else
    echo on domino
    touch ~domino/.ssh/id_rsa
    chmod 0700 ~domino/.ssh/id_rsa
    echo '-----BEGIN RSA PRIVATE KEY-----' > ~domino/.ssh/id_rsa
    echo $DKEY | sed -e 's/ /\n/g' >> ~domino/.ssh/id_rsa
    echo '-----END RSA PRIVATE KEY-----' >> ~domino/.ssh/id_rsa
    ##smount -i ~domino/.ssh/id_rsa
    ##rm ~domino/.ssh/id_rsa
fi

rsync -avz -e 'ssh -o StrictHostKeyChecking=no' . ec2-user@shiny.rwc.bms.com:Shiny/T2/ 
rm ~domino/.ssh/id_rsa















