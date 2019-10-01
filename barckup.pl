#!/bin/bash

set -e
umask 0002

# here
IDENTITY=~/.ssh/id_ed25519_barckup
ARCHIVE_DIR=/home/juerd/barckups
ARCHIVE=$ARCHIVE_DIR/`date +%Y%m%d-%H%M%S`.tgz

# there
USER=barckup
HOST=2a0e:5700:4:11::cafe
DIR=/home/bar
FILES='revbank.{accounts,products,market} .revbank.{log,undo}'

ssh -i $IDENTITY $USER@$HOST "cat > script.sh && cd $DIR && tar -cz $FILES && echo $HOSTNAME:$ARCHIVE > ~/last_success" < $0 > $ARCHIVE

tar -xOf `ls -1t $ARCHIVE_DIR/*tgz | head -n2 | tail -n1` .revbank.log > /tmp/$$-prev
tar -xOf `ls -1t $ARCHIVE_DIR/*tgz | head -n1` .revbank.log > /tmp/$$-cur

diff -u /tmp/$$-prev /tmp/$$-cur > /tmp/$$-diff || true

if egrep -v ^--- /tmp/$$-diff | egrep -q ^-; then
    echo TAMPER DETECT
    cat /tmp/$$-diff
fi

rm /tmp/$$-{prev,cur,diff}
