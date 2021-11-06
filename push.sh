#!/bin/sh
SSH="ssh -vvqi sshkey.rsa"

eval $(ssh-agent)
ssh-add sshkey.rsa


for host in 10.42.42.45 10.42.42.47; do
    echo Pushing to $host
    $SSH -t pi@$host 'sudo mount -o rw,remount /' &&
    echo \* global &&
    rsync -e "$SSH" global.acl pi@$host:doorduino/ibuttons.acl.d/global.acl &&
#    if [ "$host" != "10.42.42.42" ]; then
#        echo \* niet-voordeur &&
#        rsync -e "$SSH" niet-voordeur.acl pi@$host:doorduino/ibuttons.acl.d/niet-voordeur.acl
#    fi &&
    $SSH -t pi@$host 'sudo mount -o ro,remount /' ||
    echo "$host failed";
    echo done!
done

# Zonder secrets en zonder comments voor extradoei
perl -nle'print s/:\w+//r if not /^\s*#/' global.acl > /home/doorduino-mqtt/ibuttons.acl

eval $(ssh-agent -k)  # kill
