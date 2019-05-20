#!/bin/bash

touch ~domino/.ssh/id_rsa
chmod 0700 ~domino/.ssh/id_rsa
echo '-----BEGIN RSA PRIVATE KEY-----' > ~domino/.ssh/id_rsa
echo $DKEY | sed -e 's/ /\n/g' >> ~domino/.ssh/id_rsa
echo '-----END RSA PRIVATE KEY-----' >> ~domino/.ssh/id_rsa
smount -i ~domino/.ssh/id_rsa


##echo running batch
##bash runBatch.sh
##echo finished
rm ~domino/.ssh/id_rsa



