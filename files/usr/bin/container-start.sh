#!/bin/bash
set -e

SCHEDID=$1
CONTAINER=monroe-$SCHEDID

if [ -f /outdir/$SCHEDID.conf ]; then
  CONFIG=$(cat /outdir/$1.conf);
  QUOTA_TRAFFIC=$(echo $CONFIG | jq .traffic);
fi
if [ -z "$QUOTA_TRAFFIC" ]; then
  QUOTA_TRAFFIC=0;
fi;

ERROR_CONTAINER_DID_NOT_START=10

# make sure network namespaces are set up
mkdir -p /var/run/netns

# Container boot counter and measurement UID

COUNT=$(cat /outdir/${SCHEDID}.counter 2>/dev/null || echo 0)
COUNT=$(($COUNT + 1))
echo $COUNT > /outdir/${SCHEDID}.counter

NODEID=$(</etc/nodeid)

### START THE CONTAINER ####################################
# TODO: parameters to be passed, e.g. nodeid
# NOTE: this assumes the container wrapper delays execution
#       until the network interfaces are available

docker run -d \
       --net=none \
       --cap-add NET_ADMIN \
       --cap-add NET_RAW \
       -v /outdir/$SCHEDID:/outdir \
       $CONTAINER \
       --guid ${SCHEDID}.${NODEID}.${COUNT}

# CID: the runtime container ID
CID=$(docker ps --no-trunc | grep $CONTAINER | awk '{print $1}' | head -n 1)

if [ -z "$CID" ]; then
    echo 'failed' > /outdir/$SCHEDID.status
    exit $ERROR_CONTAINER_DID_NOT_START;
fi

# PID: the container process ID
PID=$(docker inspect -f '{{.State.Pid}}' $CID)

if [ ! -z $PID ]; then
  echo "Started docker process $CID $PID."
  # named the container network namespace 'monroe'
  # TODO: for passive containers, start them in the existing namespace
  #       of the same name
  rm /var/run/netns/monroe || true;
  ln -s /proc/$PID/ns/net /var/run/netns/monroe;

  # to execute any command within the monroe netns, use $MNS command
  MNS="ip netns exec monroe";

  ### TRAFFIC QUOTAS #########################################

  # TODO: check whether these are to be set in $MNS, or if they could be on host
  $MNS iptables -N MONROE;
  $MNS iptables -N MONROE_QUOTA_USB0;
  $MNS iptables -N MONROE_QUOTA_USB1;
  $MNS iptables -N MONROE_QUOTA_USB2;

  $MNS iptables -A MONROE_QUOTA_USB0 -m quota --quota $QUOTA_TRAFFIC -j ACCEPT;
  $MNS iptables -A MONROE_QUOTA_USB0 -j DROP;
  $MNS iptables -A MONROE_QUOTA_USB1 -m quota --quota $QUOTA_TRAFFIC -j ACCEPT;
  $MNS iptables -A MONROE_QUOTA_USB1 -j DROP;
  $MNS iptables -A MONROE_QUOTA_USB2 -m quota --quota $QUOTA_TRAFFIC -j ACCEPT;
  $MNS iptables -A MONROE_QUOTA_USB2 -j DROP;

  $MNS iptables -A MONROE -i usb0 -j MONROE_QUOTA_USB0;
  $MNS iptables -A MONROE -i usb1 -j MONROE_QUOTA_USB1;
  $MNS iptables -A MONROE -i usb2 -j MONROE_QUOTA_USB2;

  $MNS iptables -A OUTPUT -j MONROE;
  $MNS iptables -A INPUT -j MONROE;

  ### NETWORK INTERFACES #####################################

  # TODO: get these assigned by the scheduler
  INTERFACES="usb0 usb1 usb2 wlan0 eth0";
  for IF in $INTERFACES; do
      if [ -z "$(ip link|grep $IF)" ]; then continue; fi

      ip link add link $IF montmp type macvlan;
      ip link set montmp netns monroe;
      $MNS ip link set montmp name $IF;

      # TODO: do a proper network configuration, or run multi inside the container
      $MNS ifconfig $IF up;
   done
   $MNS multi_client -d;

else
  echo 'failed' > /outdir/$SCHEDID.status
  exit $ERROR_CONTAINER_DID_NOT_START;
fi
 
echo 'started' > /outdir/$SCHEDID.status
# TODO log status to sysevent and return a success value to the scheduler
