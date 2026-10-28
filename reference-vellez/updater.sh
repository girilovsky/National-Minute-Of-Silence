#!/bin/bash
BKI_LOG=$UM_MOUNTPOINT/BKI_info.txt
CURRENT_HOSTNAME=`cat /etc/hostname | tr -d " \t\n\r"`
echo >>$BKI_LOG
echo `date` >>$BKI_LOG
echo Device $CURRENT_HOSTNAME >>$BKI_LOG
echo >>$BKI_LOG
mkdir /opt/vellez/timer
cp $UM_MOUNTPOINT/opt/vellez/timer/* /opt/vellez/timer
chmod 755 /opt/vellez/timer/play_mp3
chmod 644 /opt/vellez/timer/*.mp3
#echo "0 9 * * * /opt/vellez/timer/play_mp3 /opt/vellez/timer/99_silent_m.mp3" >>/var/spool/cron/crontabs/root
crontab  /opt/vellez/timer/sil_minute
rm /opt/vellez/timer/sil_minute
crontab -l >>$BKI_LOG
