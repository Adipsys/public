#!/bin/bash

USAGE="Usage: -d DATABASEFILE -v VOLUMEDATAFILE -t TARGETVOL -c MAINCONTAINER -p DBPASSWORD"

while getopts "d:v:t:c:p:" option; do
    case "${option}" in
	d)
	    DATABASEFILE=${OPTARG}
	    ;;
	v)
	    VOLUMEDATAFILE=${OPTARG}
	    ;;
	t)
	    TARGETVOL=${OPTARG}
	    ;;
        c)
            MAINCONTAINER=${OPTARG}
            ;;
        p)
            DBPASSWORD=${OPTARG}
            ;;
        *)
            echo "Invalid parameter used !"
            echo "$USAGE"
            ;;
    esac
done
#shift $((OPTIND-1))

DATE=`date +%Y-%m-%d-%H-%M-%S`

restore_database()
{
    if [ -z $MAINCONTAINER ] ; then
        echo "Missing mandatory MAINCONTAINER parameter !"
        echo $USAGE
        exit 1
    else
        CONTAINERFULLNAME=$(docker ps --format "{{.Names}}" | grep "$MAINCONTAINER")
    fi
    
    if [ -z $DBPASSWORD ]; then
        echo "Missing mandatory DBPASSWORD parameter !"
        exit 1
    fi
    
    echo "WARNING : TARGET DATABASE on $MAINCONTAINER WILL BE OVERWRITTEN !!!!! (CTRL+C TO CANCEL)"
    read
    
	echo -e "- Restoring $DATABASEFILE to $CONTAINERFULLNAME\n"
	gunzip < $DATABASEFILE | docker exec -i $CONTAINERFULLNAME mysql -h hm-db -u root -p$DBPASSWORD
}

restore_volume()
{
    if [ -z "$TARGETVOL" ] ; then
        echo "Missing mandatory TARGETVOL parameter !"
        echo $USAGE
        exit 1
    fi
    echo "WARNING : TARGET VOLUME $TARGETVOL WILL BE OVERWRITTEN !!!!! (CTRL+C TO CANCEL)"
    read
    
	echo "- Restoring $VOLUMEDATAFILE to $TARGETVOL"
	docker run --rm -v $TARGETVOL:/var/www -v $VOLUMEDATAFILE:/backups/volume.tar.gz debian:jessie-slim bash -c "cd /var/www && tar xzf /backups/volume.tar.gz ."
	echo -e "\n Please restart the main container"
}

    if [ -z "$VOLUMEDATAFILE" ] && [ -z "$DATABASEFILE" ]; then
            echo -e "No DATABASEFILE or VOLUMEDATAFILE\n$USAGE"
            exit 1
    fi

    if [ -n "$VOLUMEDATAFILE" ]; then
                if [ -f "$VOLUMEDATAFILE" ]; then
                restore_volume
                else
                    echo "File $VOLUMEDATAFILE not found"
                fi
    fi

    if [ -n "$DATABASEFILE" ]; then
                if [ -f "$DATABASEFILE" ]; then
                restore_database
                else
                    echo "File $DATABASEFILE not found"
                fi
    fi

