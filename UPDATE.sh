#!/bin/sh
rsync root@gateway:/home/doorduino-mqtt/doorduino-mqtt.pl .
rsync root@gateway:/etc/systemd/system/doorduino-mqtt.service .
rsync root@gateway:/home/mqtt2irc/mqtt2irc.pl .
rsync root@gateway:/etc/systemd/system/mqtt2irc.service .
rsync root@gateway:/home/barckup/script.sh barckup.pl
rsync root@gateway:/home/bar/.irssi/scripts/saysomething.pl .
rsync root@doorduino-zuid:/home/pi/unlock-via-mqtt.pl .
rsync root@doorduino-zuid:/etc/systemd/system/unlock-via-mqtt.service .
rsync root@10.42.66.3:/root/mqtt-sounds/mqtt-sounds.pl .
rsync root@10.42.66.3:/root/mqtt-sounds/squeeze-volume.pl .



