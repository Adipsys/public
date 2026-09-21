#!/bin/bash

USAGE="Usage: -d DAYSTOPURGE -c CONTAINERNAME (or all) -p PASSWORD -t TARGETDIR"

while getopts "c:p:t:d:" option; do
    case "${option}" in
	c)
	    CONTAINERNAME=${OPTARG}
	    ;;
	p)
	    PASSWORD=${OPTARG}
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
TARGETFILE="docker_database_$CONTAINERNAME_$DATE.tar.gz"
LOG="/var/log/docker_backup.log"

if [ -z $CONTAINERNAME ] ; then
        echo "Missing mandatory CONTAINERNAME parameter !"
        echo $USAGE
	exit 1
else 
    if [ $CONTAINERNAME == "all" ]; then
        echo "Will backup all db containers !"
    else
	    CONTAINERFULLNAME=$(docker ps --format "{{.Names}}" | grep "$CONTAINERNAME")
	    echo "Cantainer full name is $CONTAINERFULLNAME"
    fi
fi

if [ -z $PASSWORD ] ; then
        echo "Missing mandatory PASSWORD parameter !"
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
    if [ $CONTAINERNAME == "all" ]; then
        if [[ $DAYSTOPURGE -gt 0 ]]; then
            for container in $(docker ps --format "{{.Names}}"|grep -e hm-db -e dnsp-db); do
            strip=$(echo $container|cut -d "." -f1)
            echo "Cleaning $strip ..."
            find $TARGETDIR -name "docker_database_$strip-*.sql.gz" -mtime +$DAYSTOPURGE -exec rm {} \; >> $LOG
    	    done
        fi
	else
        if [[ $DAYSTOPURGE -gt 0 ]]; then
            echo "Purge files older than $DAYSTOPURGE days" >> $LOG
            find $TARGETDIR -name "docker_database_$CONTAINERNAME-*.sql.gz" -mtime +$DAYSTOPURGE -exec rm {} \; >> $LOG
        fi
    fi
}

backup_database()
{
    docker exec $CONTAINERFULLNAME /usr/bin/mysqldump -u root --password=$PASSWORD --all-databases | gzip -9 > $TARGETDIR/docker_database_$CONTAINERNAME-$DATE.sql.gz
}

backup_all_databases()
{
    for container in $(docker ps --format "{{.Names}}"|grep -e hm-db -e dnsp-db -e studio-db); do
        strip=$(echo $container|cut -d "." -f1)
        echo "Backuping $strip ..."
        docker exec $container /usr/bin/mysqldump -u root --password=$PASSWORD --all-databases | gzip -9 > $TARGETDIR/docker_database_$strip-$DATE.sql.gz
    done
}

if [ $CONTAINERNAME == "all" ]; then
        backup_all_databases
    else        
        echo "Running Database Backup on $DATE" >> $LOG
        echo "Running Database Backup on $DATE"
        backup_database
fi

if [ -n "$DAYSTOPURGE" ]; then
	echo "Cleaning Database Backup on $DATE" >> $LOG
	echo "Cleaning Database Backup on $DATE"
	backup_purge
fi
