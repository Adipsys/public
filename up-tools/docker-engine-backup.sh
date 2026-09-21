#!/bin/bash

USAGE="Usage: -d DAYSTOPURGE -s SOURCEDIR -t TARGETDIR"

while getopts "s:t:d:" option; do
    case "${option}" in
	s)
	    SOURCEDIR=${OPTARG}
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
TARGETFILE="docker_engine_$DATE.tar.gz"
LOG="/var/log/docker_backup.log"

if [ -z $SOURCEDIR ] ; then
        echo "Missing mandatory SOURCEDIR parameter !"
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
		find $TARGETDIR -name "docker_engine_*.tar.gz" -mtime +$DAYSTOPURGE -exec rm {} \; >> $LOG
	fi
}

backup_engine()
{
	if [ -d "$SOURCEDIR" ] && [ -d "$TARGETDIR" ]; then
	tar cvzf $TARGETDIR/$TARGETFILE $SOURCEDIR
else
	echo "Missing directory !" >> $LOG
	echo "Missing directory !"
	fi
}

if [ -n "$DAYSTOPURGE" ]; then
    echo "Running Engine Backup on $DATE" >> $LOG
    echo "Running Engine Backup on $DATE"
    backup_engine
	echo "Cleaning Engine Backup on $DATE" >> $LOG
	echo "Cleaning Engine Backup on $DATE"
	backup_purge
else
	echo "Running Engine Backup on $DATE" >> $LOG
	echo "Running Engine Backup on $DATE"
	backup_engine
fi
