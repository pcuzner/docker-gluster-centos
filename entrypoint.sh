#!/bin/bash
#
#

set -e

if [ -e /utils.sh ]; then 
  . /utils.sh
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
  
  # attempt to get the config data 
  etcd_response=$(curl -s http://${KV_IP}:4001/v2/keys/gluster/config/$host_name)
  if [[ "$etcd_data" == *"error"* ]]; then  
  
    log_msg "KV config entry for the running host does not exist"
    return
    
  else
    etcd_data=$(echo $etcd_response | \
				python -c 'import json,sys;obj=json.load(sys.stdin);print obj["node"]["value"]')
    
    NODE_IP=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin);print obj["IPAddress"]' 2> /dev/null)
	if [ $? -gt 0 ]; then 
	  unset NODE_IP
	fi
	log_msg "-> Node IP .... $NODE_IP"			
    NODENAME=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin);print obj["NodeName"]' 2> /dev/null)
    if [ $? -gt 0 ]; then 
	  unset NODENAME
	fi			
	log_msg "-> Node Name .. $NODENAME"			
	PEER_UUID=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin);print obj["PeerUUID"]' 2> /dev/null)
	if [ $? -gt 0 ]; then 
	  unset PEER_UUID
	fi	
	log_msg "-> UUID ....... $PEER_UUID"				
	
	PEER_LIST=$(echo $etcd_data | \
				python -c 'import json,sys;config=json.load(sys.stdin); peer_ips=",".join([peer["IP"] for peer in config["PeerList"]]) if "PeerList" in config else None; print peer_ips' 2> /dev/null)
	if [ "$PEER_LIST" == "None" ]; then 
	  unset PEER_LIST
	  log_msg "-> container will not attempt to form a cluster"

	else		
	  log_msg "-> Peers ...... $PEER_LIST"
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

    # To proceed, we need a NODE_IP and NODENAME to setup the container
    # on the hosts interface        
    if [[ -z ${NODE_IP+x} || -z ${NODENAME+x} ]]; then 
    
      log_msg "--net=host used but NODE_IP/NODENAME are not available. Can not start the container"
      exit 1
      
    fi
  fi  
}

function IP_OK {
  #
  # check that the NODE_IP matches one of the IP's on the host machine
  #
  
  IFS=$'\n' IP_LIST=($(ip -4 -o addr | sed -e "s/\//\ /g"| awk '{print $4;}'))
  if element_in $NODE_IP ${IP_LIST[@]} ; then 
    return 0
  else
    return 1 
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
    
    log_msg "NODE_IP is set to $NODE_IP, checking this IP is available on this host"
    if IP_OK; then 
        
      # IP address provided is valid, so configure the services
      log_msg "$NODE_IP is valid"
      log_msg "Updating glusterd to bind only to $NODE_IP"
      sed -i.bkup "/end-volume/i \ \ \ \ option transport.socket.bind-address ${NODE_IP}" /etc/glusterfs/glusterd.vol
      log_msg "Updating sshd to bind only to $NODE_IP"
      sed -i.bkup "/#ListenAddress 0/c\ListenAddress $NODE_IP" /etc/ssh/sshd_config
      log_msg "Setting container hostname to $NODENAME"
      cp /etc/hostname /etc/hostname.bkup
      echo $NODENAME | tee /etc/hostname 2&>1 
      hostname $NODENAME
        
    else
        
      log_msg "IP address of $NODE_IP is not available on this host. Can not start the container"
      exit 1
      
    fi
  fi
 
}

set_network_config

if [ -e /var/lib/glusterd/glusterd.info ]; then 

  if [ -z ${PEER_UUID+x} ]; then  
  
    log_msg "Renaming the pre-built UUID file to force a new UUID to be generated on glusterd startup"
    mv /var/lib/glusterd/glusterd.{info,info.bkup}
    
  else
  
    log_msg "Updating container's UUID to the value from the KV store ($PEER_UUID)"
    sed -i.bak "/^UUID=/c\UUID=${PEER_UUID}" /var/lib/glusterd/glusterd.info
    
  fi
  
fi

if glusterd_port_available; then 

  configure_network
  
  # if we have peers defined, then fork a shell to try and create the cluster
  if [ ! -z ${PEER_LIST+x} ] ; then 
    log_msg "forking the create_cluster process"
    /create_cluster.sh "$NODE_IP" "$PEER_LIST" &
  fi
  
  # start normal systemd start-up process
  run_services
  
else

  log_msg "Unable to start the container, a gluster instance is already running on this host"
  
fi




