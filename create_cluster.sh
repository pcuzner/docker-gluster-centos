#!/bin/bash

CHECK_INTERVAL=15
ABORT_TIMEOUT=600
FOUND_OPEN=0
GLUSTERD_PORT=24007

if [ -e /build/utils.sh ]; then 
	. /build/utils.sh
fi

function detect_glusterd_nodes {
	local elapsed=0
	
	local all_nodes=("$LOCAL_IP" "${IP_LIST[@]}")

	while [ $elapsed -lt $ABORT_TIMEOUT ]; do 
	
		FOUND_OPEN=0
		sleep $CHECK_INTERVAL
		elapsed=$((elapsed + CHECK_INTERVAL))
		for peer_ip in "${all_nodes[@]}"; do 
	
			if port_open $peer_ip $GLUSTERD_PORT; then 
				log_msg "glusterd detected on $peer_ip"
				FOUND_OPEN=$((FOUND_OPEN + 1))
			else
				log_msg "glusterd not detected on $peer_ip"
			fi
			
		done
		
		if [ $FOUND_OPEN -eq $((NUM_PEERS + 1)) ]; then 
			break
		fi
		
	done

	
}

function create_cluster {
	local total_nodes=$((NUM_PEERS + 1))
	local peers_added=0
	log_msg "All nodes required are available, creating a trusted storage pool of $total_nodes nodes"
	for peer_ip in "${IP_LIST[@]}"; do 
		local glfs_response=$(gluster peer probe $peer_ip)
		if [ $? -eq 0 ]; then 
		  log_msg "Added node $peer_ip .... ( $glfs_response)"
		  peers_added=$((peers_added + 1))
		else
		  log_msg "Addition of $peer_ip to the cluster failed ($glfs_response)"
		  exit 1
		fi
	done
	
	if [ $peers_added -eq $NUM_PEERS ]; then
	  log_msg "All nodes requested added to the cluster successfully"
	else
	  log_msg "Error encountered adding node(s) to the cluster. Unable to continue"
	fi
}

# $1 = local IP
# $2 = comma separated list of peer IPs
LOCAL_IP=$1
PEERS=$2
IFS=',' read -a IP_LIST <<< "$PEERS"

NUM_PEERS=${#IP_LIST[@]}

detect_glusterd_nodes

if [ $FOUND_OPEN -eq $((NUM_PEERS + 1)) ] ; then 
  create_cluster
else
  log_msg "Not all peers detected, and timeout threshold ($ABORT_TIMEOUT) exceeded."
fi


