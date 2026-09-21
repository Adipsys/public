#!/bin/bash

FILENAME="host_infos.txt"

get-host-infos() {
	HOSTNAME=$(hostname)
	OS-VERSION=$(cat /etc/debian_version)
	OS-UPTIME=$(uptime|cut -d " " -f4)
	OS-LOAD=$(cat /proc/loadavg| cut -d " " -f 2)
	DOCKER-VERSION=$(docker -v)
	DOCKER-RUNNING-CONTAINERS=$(docker ps|grep -v ID|wc -l)
	DOCKER-SERVICES=$(docker service ls|grep -v ID|wc -l)
	DOCKER-NODES=$(docker node ls|grep -v ID| wc -l)
}

write-infos-to-volumes() {
	for VOLUME in $(docker volume ls|grep local|tr -s " "|cut -d " " -f 2|grep -e "hm-data" -e "dnsp-conf"); do
		echo "Proceeding with $VOLUME..."
		VOLUME-PATH=$(docker volume inspect $VOLUME|grep Mountpoint|tr -s " "|cut -d " " -f3|tr -d "\""|tr -d ",")
		echo "HOSTNAME=$HOSTNAME" > $VOLUME-PATH/$FILENAME
		echo "OS-VERSION=$OS-VERSION" >> $VOLUME-PATH/$FILENAME
		echo "OS-UPTIME=$OS-UPTIME" >> $VOLUME-PATH/$FILENAME
		echo "OS-LOAD=$OS-LOAD" >> $VOLUME-PATH/$FILENAME
		echo "DOCKER-VERSION=$DOCKER-VERSION" >> $VOLUME-PATH/$FILENAME
		echo "DOCKER-RUNNING-CONTAINERS=$DOCKER-RUNNING-CONTAINERS" >> $VOLUME-PATH/$FILENAME
		echo "DOCKER-SERVICES=$DOCKER-SERVICES" >> $VOLUME-PATH/$FILENAME
		echo "DOCKER-NODES=$DOCKER-NODES" >> $VOLUME-PATH/$FILENAME
	done
}
