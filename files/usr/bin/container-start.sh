#!/bin/bash
set -e

SCHEDID=$1
STATUS=$2
CONTAINER=monroe-$SCHEDID

BASEDIR=/experiments/user
STATUSDIR=$BASEDIR
mkdir -p $BASEDIR

if [ -f $BASEDIR/$SCHEDID.conf ]; then
  CONFIG=$(cat $BASEDIR/$SCHEDID.conf);
  IS_INTERNAL=$(echo $CONFIG | jq -r '.internal // empty');
  IS_SSH=$(echo $CONFIG | jq -r '.ssh // empty');
  BDEXT=$(echo $CONFIG | jq -r '.basedir // empty');
  EDUROAM_IDENTITY=$(echo $CONFIG | jq -r '._eduroam.identity // empty');
  EDUROAM_HASH=$(echo $CONFIG | jq -r '._eduroam.hash // empty');
  IS_VM=$(echo $CONFIG | jq -r '.vm // empty');
  NEAT_PROXY=$(echo $CONFIG | jq -r '.neat // empty');
fi
if [ ! -z "$IS_INTERNAL" ]; then
  BASEDIR=/experiments/monroe${BDEXT}
  mkdir -p $BASEDIR
  echo $CONFIG > $BASEDIR/$SCHEDID.conf
  # redirect output to log file
  exec > $BASEDIR/start.log 2>&1
else
  exec >> $BASEDIR/$SCHEDID/start.log 2>&1
fi

VM_CONF_DIR=$BASEDIR/$SCHEDID.confdir

NOERROR_CONTAINER_IS_RUNNING=0

ERROR_CONTAINER_DID_NOT_START=10
ERROR_NETWORK_CONTEXT_NOT_FOUND=11
ERROR_IMAGE_NOT_FOUND=12
ERROR_MAINTENANCE_MODE=13

echo -n "Checking for maintenance mode... "
MAINTENANCE=$(cat /monroe/maintenance/enabled || echo 0)
if [ $MAINTENANCE -eq 1 ]; then
   echo 'failed; node is in maintenance mode.' > $STATUSDIR/$SCHEDID.status
   echo "enabled."
   exit $ERROR_MAINTENANCE_MODE;
fi
echo "disabled."

echo -n "Ensure network and containers are set up... "
mkdir -p /var/run/netns

# Container boot counter and measurement UID

COUNT=$(cat $BASEDIR/${SCHEDID}.counter 2>/dev/null || echo 0)
COUNT=$(($COUNT + 1))
echo $COUNT > $BASEDIR/${SCHEDID}.counter

NODEID=$(</etc/nodeid)
IMAGEID=$(docker images -q --no-trunc monroe-$SCHEDID)

if [ -z "$IMAGEID" ]; then
    echo "experiment container not found."
    exit $ERROR_IMAGE_NOT_FOUND;
fi

GUID="${IMAGEID}.${SCHEDID}.${NODEID}.${COUNT}"

# replace guid in the configuration

CONFIG=$(echo $CONFIG | jq '.guid="'$GUID'"|.nodeid="'$NODEID'"')
echo $CONFIG > $BASEDIR/$SCHEDID.conf
echo "ok."

# setup eduroam if available

if [ ! -z "$EDUROAM_IDENTITY" ]; then
    /usr/bin/eduroam-login.sh $EDUROAM_IDENTITY $EDUROAM_HASH & 
fi

### START THE CONTAINER ###############################################

echo -n "Starting container... "
if [ -d $BASEDIR/$SCHEDID ]; then
    MOUNT_DISK="-v $BASEDIR/$SCHEDID:/monroe/results -v $BASEDIR/$SCHEDID:/outdir"
fi
if [ -d /experiments/monroe/tstat ]; then
    TSTAT_DISK="-v /experiments/monroe/tstat:/monroe/tstat:ro"
fi

# check that this container is not running yet
if [ ! -z "$(docker ps | grep monroe-$SCHEDID)" ]; then
    echo "already running."
    exit $NOERROR_CONTAINER_IS_RUNNING;
fi

# identify the monroe/noop container, running in the
# network namespace called 'monroe'
MONROE_NAMESPACE=$(docker ps --no-trunc -aqf name=monroe-namespace)
if [ -z "$MONROE_NAMESPACE" ]; then
    echo "network context missing."
    exit $ERROR_NETWORK_CONTEXT_NOT_FOUND;
fi

if [ ! -z "$IS_SSH" ]; then
    OVERRIDE_ENTRYPOINT=" --entrypoint=dumb-init "
    OVERRIDE_PARAMETERS=" /bin/bash /usr/bin/monroe-sshtunnel-client.sh "
fi

cp /etc/resolv.conf $BASEDIR/$SCHEDID/resolv.conf.tmp

### ENABLE NEAT PROXY #################################################
## Copied from monroe-experiments #####
INTERFACES_BR="$(modems | jq -r .[].ifname) eth0 wlan0"
VETH_IPRANGE=172.18
function ifnum {
  # generate a unique static IP for each interface name
  # $1 - interface name (e.g wwan0)
  echo -n "$VETH_IPRANGE."
  echo $1 | sed -e 's/\([^0-9]\+\)\([0-9]\+\)/\2-\1/g' \
    -e 's/-wwan/1/g' \
    -e 's/-ppp/2/g' \
    -e 's/-eth/3/g' \
    -e 's/-usb/4/g' \
    -e 's/-wlan/5/g' \
    -e 's/^0*//g'
}

if [ ! -z "$NEAT_PROXY"  ]; then
  # If proxy is enabled, then configure TPROXY iptables rules
  # to divert TCP traffic via the proxy on all available interfaces
  echo "TORO neat-proxy is enabled"
  for IF in $INTERFACES_BR; do
    if [ -z "$(ip link|grep ${IF}Br:)" ]; then
      # Firewall rules to set up TPROXY
      TARGET="/etc/circle.d/60-$IF-neat-proxy.rules"
      if [ ! -f ${TARGET} ]; then
        IPRANGE=$(ifnum $IF)
	RULES="\
\${ipt4} -A INPUT -p tcp -s ${IPRANGE}.0/24 -j ACCEPT
\${ipt4} -t mangle -A PREROUTING -p tcp -i ${IF}Br -j TPROXY --tproxy-mark 0x1/0x1 --on-port 9876"
        echo "$RULES" > $TARGET
        echo "enabled neat-proxy on ${IF}"
        logger -t monroe-experiments "enabled neat-proxy on ${IF}"
      fi
    fi
   done
fi

# drop all network traffic for 30 seconds (idle period)
nohup /bin/bash -c 'sleep 35; circle start' > /dev/null &
iptables -F
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
sleep 30
circle start

##########################################################################

if [ ! -z "$IS_VM" ]; then
    echo "Container is a vm, trying to deploy... "
    /usr/bin/vm-deploy.sh $SCHEDID
    echo -n "Copying vm config files..."
    mkdir -p $VM_CONF_DIR
    cp $BASEDIR/$SCHEDID/resolv.conf.tmp $VM_CONF_DIR/resolv.conf
    cp $BASEDIR/$SCHEDID.conf $VM_CONF_DIR/config
    cp  /etc/nodeid $VM_CONF_DIR/nodeid
    cp /tmp/dnsmasq-servers-netns-monroe.conf $VM_CONF_DIR/dns
    echo "ok."

    echo "Starting VM... "
    # Kicking alive the vm specific stuff
    /usr/bin/vm-start.sh $SCHEDID $OVERRIDE_PARAMETERS
    echo "vm started." 
else
    CID_ON_START=$(docker run -d $OVERRIDE_ENTRYPOINT  \
           --name=monroe-$SCHEDID \
           --net=container:$MONROE_NAMESPACE \
           --cap-add NET_ADMIN \
           --cap-add NET_RAW \
           --shm-size=1G \
           -v $BASEDIR/$SCHEDID/resolv.conf.tmp:/etc/resolv.conf \
           -v $BASEDIR/$SCHEDID.conf:/monroe/config:ro \
           -v /etc/nodeid:/nodeid:ro \
           -v /tmp/dnsmasq-servers-netns-monroe.conf:/dns:ro \
           $MOUNT_DISK \
           $TSTAT_DISK \
           $CONTAINER $OVERRIDE_PARAMETERS)
	   echo "ok."
fi

# start accounting
echo "Starting accounting."
/usr/bin/usage-defaults 2>/dev/null || true

if [ -z "$IS_VM" ]; then
    # CID: the runtime container ID
    CID=$(docker ps --no-trunc | grep $CONTAINER | awk '{print $1}' | head -n 1)

    if [ -z "$CID" ]; then
        echo 'failed; container exited immediately' > $STATUSDIR/$SCHEDID.status
        echo "Container exited immediately."
        echo "Log output:"
        docker logs -t $CID_ON_START || true
        echo ""
        exit $ERROR_CONTAINER_DID_NOT_START;
    fi

    # PID: the container process ID
    PID=$(docker inspect -f '{{.State.Pid}}' $CID)
    PNAME="docker"
    CONTAINER_TECHONOLOGY="container"
else
    CID=""
    PID=$(cat $BASEDIR/$SCHEDID.pid)
    PNAME="kvm"
    CONTAINER_TECHONOLOGY="vm"
fi

if [ ! -z $PID ]; then
  echo "Started $PNAME process $CID $PID."
else
  echo "failed; $CONTAINER_TECHONOLOGY exited immediately" > $STATUSDIR/$SCHEDID.status
  echo "$CONTAINER_TECHONOLOGY exited immediately."
  if [ -z "$IS_VM" ]; then
    echo "Log output:"
    docker logs -t $CID_ON_START || true
  fi
  exit $ERROR_CONTAINER_DID_NOT_START;  #Different exit code for VM?
fi

echo $PID > $BASEDIR/$SCHEDID.pid
if [ -z "$STATUS" ]; then
  echo 'started' > $STATUSDIR/$SCHEDID.status
else
  echo $STATUS > $STATUSDIR/$SCHEDID.status
fi
sysevent -t Scheduling.Task.Started -k id -v $SCHEDID
echo "Startup finished $(date)."
