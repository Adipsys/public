#!/bin/bash

USAGE="Usage: -v VOLUMENAME|all -t TARGETDIR -d DAYSTOPURGE"

while getopts "v:t:d:" option; do
    case "${option}" in
	v)
	    VOLUMENAME=${OPTARG}
	    ;;
        t)
            TARGETDIR=${OPTARG}
            ;;
        d)
            DAYSTOPURGE=${OPTARG}
            ;;
        *)
            echo "Invalid parameter used !"
            echo "$USAGE"
            ;;
    esac
done
#shift $((OPTIND-1))

DATE=`date +%Y-%m-%d-%H-%M-%S`
TARGETFILE="docker_volume_$VOLUMENAME_$DATE.tar.gz"
LOG="/var/log/docker_backup.log"

if [ -z $VOLUMENAME ] ; then
        echo "Missing mandatory VOLUMENAME parameter !"
        echo $USAGE
	exit 1
fi

if [ -z $TARGETDIR ] ; then
        echo "Missing mandatory TARGETDIR parameter !"
        echo $USAGE
	exit 1
fi

if [ ! -d $TARGETDIR ]; then
        echo "Target directory $TARGETDIR missing"
        exit 1
fi

backup_purge()
{
	if [[ $DAYSTOPURGE -gt 0 ]]; then
		echo "Purge files older than $DAYSTOPURGE days" >> $LOG
		find $TARGETDIR -name "docker_volume_$VOLUMENAME-*.tar.gz" -mtime +$DAYSTOPURGE -exec rm {} \; >> $LOG
	fi
}

backup_purge_all()
{
for VOLUME in $(docker volume ls |grep local|tr -s " "|cut -d " " -f 2); do
    echo "Proceeding with cleaning $VOLUME..."
    if [[ $DAYSTOPURGE -gt 0 ]]; then
        echo "Purge files older than $DAYSTOPURGE days" >> $LOG
        find $TARGETDIR -name "docker_volume_$VOLUME-*.tar.gz" -mtime +$DAYSTOPURGE -exec rm {} \; >> $LOG
    fi
done
}

backup_volume()
{
	docker run --rm -v $VOLUMENAME:/var/www -v $TARGETDIR:/backups/ debian:jessie-slim bash -c "cd /var/www && tar cvzf /backups/docker_volume_$VOLUMENAME-$DATE.tar.gz ." >> $LOG
}

backup_all_volumes()
{
echo "Will exclude volumes with db or logs in their name !"
for VOLUME in $(docker volume ls |grep local|tr -s " "|cut -d " " -f 2|grep -v "db"|grep -v "logs"|grep -v "dashboard"|grep -v "master"); do
    echo "Proceeding with $VOLUME..."
    docker run --rm -v $VOLUME:/var/www -v $TARGETDIR:/backups/ debian:jessie-slim bash -c "cd /var/www && tar cvzf /backups/docker_volume_$VOLUME-$DATE.tar.gz ." >> $LOG
done
}

if [ -n "$DAYSTOPURGE" ]; then
    if [ "$VOLUMENAME" == "all" ]; then
        echo "Running Volume Backup on $DATE" >> $LOG
        echo "Running Volume Backup on $DATE"
        backup_all_volumes
        echo "Cleaning Volume Backup on $DATE" >> $LOG
        echo "Cleaning Volume Backup on $DATE"
        backup_purge_all
    else
        echo "Running Volume Backup on $DATE" >> $LOG
        echo "Running Volume Backup on $DATE"
        backup_volume
        echo "Cleaning Volume Backup on $DATE" >> $LOG
        echo "Cleaning Volume Backup on $DATE"
        backup_purge
    fi
else
    if [ "$VOLUMENAME" == "all" ]; then
        echo "Running Volume Backup on $DATE" >> $LOG
        echo "Running Volume Backup on $DATE"
        backup_all_volumes
    else
        echo "Running Volume Backup on $DATE" >> $LOG
        echo "Running Volume Backup on $DATE"
        backup_volume
    fi
fi
