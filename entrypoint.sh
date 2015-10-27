#!/bin/bash
#
#

# port 2379 is assumed, since this is the IANA registered client port
# for etcd
ETCD_PORT=2379

if [ -e /build/utils.sh ]; then 
  . /build/utils.sh
fi

function glusterd_port_available {

  netstat -4 -tan | awk '/^tcp/ {print $4;}' | grep 24007 &> /dev/null
  if [ $? -eq 0 ]; then 
    return 1
  else
    return 0
  fi
}

function run_services {
  #
  # Start systemd to start all enabled services
  #
  
  log_msg "Starting services"
  exec /usr/sbin/init
  
}

function get_config_from_kvstore {
  local host_name=$(hostname -s)
 
  if ! port_open ${KV_IP} ${ETCD_PORT}; then 
    log_msg "Unable to detect etcd at http://${KV_IP}:${ETCD_PORT}. Can not continue"
    exit 1
  fi 

 
  # at this point, etcd is present, so we attempt to get the config data for this host 
  etcd_response=$(curl -s http://${KV_IP}:${ETCD_PORT}/v2/keys/gluster/config/$host_name)
  if [[ "$etcd_data" == *"error"* ]]; then  
  
    log_msg "etcd config entry for the running host does not exist"
    return
    
  else
    etcd_data=$(echo $etcd_response | \
				python -c 'import json,sys;obj=json.load(sys.stdin);print obj["node"]["value"]')
    IP_INFO=$(echo $etcd_data | \
			python -c 'import json,sys;obj=json.load(sys.stdin); \
			resp=obj["IPAddress"] if "IPAddress" in obj else ""; \
			print resp' 2> /dev/null)
				
    if [ "$IP_INFO" != "" ]; then 
      IFS="/" read -ra IPADDR <<< "$IP_INFO"
      # need to validate the ip and netmask, but for now assume it's correct
      NODE_IP=${IPADDR[0]}
      if [ "${IPADDR[1]}" != "" ]; then 
        NETMASK=$(python -c "import socket,struct; \
				quad=socket.inet_ntoa(struct.pack('>I', (0xffffffff << (32 - ${IPADDR[1]})) & 0xffffffff)); \
				print quad")
	  else
	    # assume /24 subnet if none provided
	    NETMASK="255.255.255.0"
	    log_msg "WARNING: IP configuration did not provide a mask,"\
				" assuming /24 subnet"
	  fi
	  
	fi
	
	log_msg "-> Gluster Node IP .... $IP_INFO"
				
    NODENAME=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin); \
				resp=obj["GlusterNodeName"] if "GlusterNodeName" in obj else ""; \
				print resp' 2> /dev/null)
    if [ "$NODENAME" == "" ]; then 
	  unset NODENAME
	fi			
	log_msg "-> Gluster Name ....... $NODENAME"			

    PEER_LIST=$(echo $etcd_data | \
				python -c 'import json,sys;config=json.load(sys.stdin); \
				peer_ips=",".join([peer["IP"] for peer in config["PeerList"]]) if "PeerList" in config else None; \
				print peer_ips' 2> /dev/null)
	if [ "$PEER_LIST" == "None" ]; then 
	  unset PEER_LIST
	  log_msg "-> container will not attempt to form a cluster"

	else		
	  log_msg "-> Peer List .......... $PEER_LIST"
	fi
  fi
}


function set_network_config {
	
  # 
  # set up the NODE_IP and NODENAME variables based on invocation
  #
  
  # if the container can't see the dockerX interface, then we're using 
  # an overlay network so default to pick up a dhcp address
  if [ ! -e /sys/class/net/docker0 ]; then 
    return
  else
    # host networking has been provided
    log_msg "Container started with --net=host"
    
    # check if invoked with use key/value store flag
    if [ $KV_IP ]; then 
    
      log_msg "KV store at 'http://$KV_IP' will be queried for container configuration"
      get_config_from_kvstore

    fi

    log_msg "Setting container hostname to $NODENAME"
    cp /etc/hostname /etc/hostname.bkup
    echo $NODENAME | tee /etc/hostname > /dev/null 
    hostname $NODENAME

    # To proceed, we need a NODE_IP and NODENAME to setup the container
    # on the hosts interface        
    if [[ -z ${NODE_IP+x} || -z ${NODENAME+x} ]]; then 
    
      log_msg "--net=host used but NODE_IP/NODENAME are not available. Can not start the container"
      exit 1
      
    fi
  fi  
}

function valid_lvname {
  local size=${#1}
  local sfx=${1: -2}
  
  # a gluster snapshot lv looks like 03613e95ee644159919541c32f45b45d_0
  # so, look at the lvname and if it looks like a snapshot return a 
  # not valid result
  if [ $size -ge 34 ] && [ $sfx == "_0" ]; then
    return 1
  else
    return 0
  fi
}


function configure_brick {
  # check if a glusterfs brick is present, and mount accordingly
  #
  # Assume the vg is called gluster, and the thin pool is called brickpool 
  local lv_list=($(lvs --noheadings -S vg_name=gluster,pool_lv=brickpool -o lv_name 2> /dev/null))
  
  if [ ${#lv_list[@]} -gt 0 ]; then 
    mkdir /gluster
    for lv in ${lv_list[@]}; do
      if valid_lvname $lv; then 
        brick=$(echo "${lv}" | sed 's/\ //g')
        log_msg "Adding LV ${brick} to fstab at /gluster/${brick}"
        mkdir /gluster/${brick}
        echo -e "/dev/gluster/${brick}\t/gluster/${brick}\t\txfs\t"\
		     	"defaults,inode64,noatime\t0 0" | tee -a /etc/fstab > /dev/null
	  else 
        log_msg "Skipping ${lv} - not a valid name to mount to the filesystem (snapshot?)"	  
      fi

    done
    log_msg "Mounting the brick(s) to this container" 
    mount -a
  else
    log_msg "No compatible disks detected on this host"
  fi
   
}

function configure_network {
  #
  # Check networking available to the container, and configure accordingly
  #
  
  if [[ -z ${NODE_IP+x} || -z ${NODENAME+x} ]]; then 
  
    log_msg "gluster container will use overlay networking (flanneld)"
    return
    
  else
    
    log_msg "checking $NODE_IP is available on this host"
    if IP_OK $NODE_IP; then 
        
      # IP address provided is valid, so configure the services
      log_msg "$NODE_IP is valid"
      
      log_msg "Checking glusterd is only binding to $NODE_IP"
      if ! grep $NODE_IP /etc/glusterfs/glusterd.vol &> /dev/null; then
        log_msg "Updating glusterd to bind only to $NODE_IP"
        sed -i.bkup "/end-volume/i \ \ \ \ option transport.socket.bind-address ${NODE_IP}" /etc/glusterfs/glusterd.vol
      else
        log_msg "glusterd already set to $NODE_IP"
      fi
      
      # ssh config and hostname settings are not persisted, so need to 
      # be reset on startup
      log_msg "Updating sshd to bind only to $NODE_IP"
      sed -i.bkup "/#ListenAddress 0/c\ListenAddress $NODE_IP" /etc/ssh/sshd_config
      
    else
        
      log_msg "IP address $NODE_IP is not available on this host. Can not start the container"
      exit 1
      
    fi
  fi
 
}

set_network_config

if [ ! -e /etc/glusterfs/glusterd.vol ]; then
  # this is the first run, so we need to seed the configuration
  log_msg "Seeding the configuration directories"
  cp -pr /build/config/etc/glusterfs/* /etc/glusterfs
  cp -pr /build/config/var/lib/glusterd/* /var/lib/glusterd
  cp -pr /build/config/var/log/glusterfs/* /var/log/glusterfs
fi

# from glusterfs 3.7.3, the peer UUID is not set after install - it's set at 1st startup
# which means fro our containers, we don't need to manipulate it at the container level

#if [ -z ${PEER_UUID+x} ]; then  
#  
#  log_msg "Renaming the pre-built UUID file to force a new UUID to be generated on glusterd startup"
#  mv /var/lib/glusterd/glusterd.{info,info.bkup}
#    
#else
#  
#  log_msg "Updating container's UUID to the value from the KV store ($PEER_UUID)"
#  sed -i.bak "/^UUID=/c\UUID=${PEER_UUID}" /var/lib/glusterd/glusterd.info
#    
#fi

if glusterd_port_available; then 

  configure_network
  
  configure_brick
  
  # if we have peers defined and the ccontainer doesn't have any existing
  # peers, fork a shell to try and create the cluster
  
  if empty_dir /var/lib/glusterd/peers  ; then 
    
    log_msg "Existing peer node definitions have not been found"  
    if [ ! -z ${PEER_LIST+x} ]; then 
      
      log_msg "Using the list of peers from the etcd configuration"
      log_msg "Forking the create_cluster process"
      /build/create_cluster.sh "$NODE_IP" "$PEER_LIST" &
      
    fi
     
  else
  
    log_msg "Using peer definition from previous container start"
    
  fi
  
  # start normal systemd start-up process
  run_services
  
else

  log_msg "Unable to start the container, a gluster instance is already running on this host"
  
fi




