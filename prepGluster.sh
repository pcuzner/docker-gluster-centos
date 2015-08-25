#!/usr/bin/bash
#
# Prepare an Atomic host environment so it can offer a persistent
# gluster container. 
#


if [ -e $(pwd)/utils.sh ]; then 
  . $(pwd)/utils.sh
fi 

function get_etcd_config {
  echo "- retrieving this hosts intended config from etcd"

  local host_name=$(hostname -s)
  
  etcd_response=$(curl -s http://${KV_IP}:4001/v2/keys/gluster/config/$host_name)
  if [[ "$etcd_response" == *"error"* ]]; then  
  
    echo "etcd config entry for this host does not exist"
    return
    
  else
    etcd_data=$(echo $etcd_response | \
				python -c 'import json,sys;obj=json.load(sys.stdin); \
				print obj["node"]["value"]')
    
    IP_INFO=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin); \
				resp=obj["IPAddress"] if "IPAddress" in obj else ""; \
				print resp' 2> /dev/null)
				
    if [ "$IP_INFO" != "" ]; then 
      IFS="/" read -ra IPADDR <<< "$IP_INFO"
      # need to validate the ip and netmask, but for now assume it's correct
      NODE_IP=${IPADDR[0]}
      NETMASK=$(python -c "import socket,struct; \
				quad=socket.inet_ntoa(struct.pack('>I', (0xffffffff << (32 - ${IPADDR[1]})) & 0xffffffff)); \
				print quad")
	fi
	
	BRICK_DEV=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin); \
				resp=obj["BrickDevice"] if "BrickDevice" in obj else ""; \
				print resp' 2> /dev/null)
    if [ "$BRICK_DEV" == "" ]; then 
	  unset BRICK_DEV
	fi
	
	ZAP_DEV=$(echo $etcd_data | \
				python -c 'import json,sys;obj=json.load(sys.stdin); \
				resp=obj["ZapDevice"] if "ZapDevice" in obj else ""; \
				print resp' 2> /dev/null)
    if [ "$ZAP_DEV" == "" ]; then 
	  unset ZAP_DEV
	fi
  fi
}

function etcd_ok {
  # validate the etcd IP addresss is OK to use
         
  if [ ${KV_IP} == "127.0.0.1" ] ;then 
    unset KV_IP
    echo 1
    return 
  fi
  
  if port_open ${KV_IP} 4001; then 
    echo 0
    return
  fi
    
  # at this point etcd can't be contacted, so etcd is NOT ok!
  echo 2
  return
       
}

function prep_directories {
  echo "- creating directories for glusterfs config and logging"  
  mkdir /etc/glusterfs \
        /var/lib/glusterd \
        /var/log/glusterfs

  echo "- resetting SELINUX context on the glusterfs directories"
  chcon -Rt svirt_sandbox_file_t /etc/glusterfs
  chcon -Rt svirt_sandbox_file_t /var/lib/glusterd
  chcon -Rt svirt_sandbox_file_t /var/log/glusterfs
}

function disk_used {
  return $(blkid $1 &> /dev/null; echo $?)
}

function format_device {
	
  # Addition logic is needed here to account for RAID LUNs to ensure the 
  # alignment is correct. The code here is ONLY suitable for POC/demo
  # purposes.	
	
  echo "- configuring $BRICK_DEV with LVM"
  
  pvcreate $BRICK_DEV
  vgcreate gluster $BRICK_DEV
  
  local meta_data_size
  local size_limit=1099511627776
  local disk_size=$(vgs gluster --noheadings --nosuffix --units b -o vg_size)
  local extent_size=$(vgs gluster --nosuffix --unit b --noheadings -o vg_extent_size)
  local vg_free=$(vgs gluster --noheadings -o vg_free_count)
  
  # Use 'extents' as unit of calculation
  if [ ${disk_size} -gt ${size_limit} ]; then 
    # meta data size is 16GB
    meta_data_size=$((17179869184/extent_size))
  else
    # metadata size is 0.5% of the disk's extent count
    meta_data_size=$((vg_free/200))
  fi
  
  # create the pool - must be a multiple of 512
  total_meta_data=$((meta_data_size*2))
  local pool_size=$((vg_free-total_meta_data))
  lvcreate -L $((pool_size*extent_size))b -T gluster/brickpool -c 256K \
           --poolmetadatasize $((meta_data_size*extent_size))b \
           --poolmetadataspare y
  
  # lvcreate thin dev @ 90% of the brick pool, assuming snapshot support
  local lv_size=$(((pool_size/100)*90))
  lvcreate -V $((lv_size*extent_size))b -T gluster/brickpool -n brick1
  
  echo "- Creating XFS filesystem"
  # mkfs.xfs
  mkfs.xfs -i size=512 /dev/gluster/brick1 1> /dev/null
  if [ $? -eq 0 ]; then 
    echo "- filesystem created successfully"
  else 
    exit 1
  fi
}

function prep_disk {
  # Assumptions
  # 1. a host will provide a single RAID-6 LUN
  # 2. logic deals with prior runs, not random disk configurations
  #
  	
  echo -e "\nPreparing $BRICK_DEV for gluster use"
  if ! disk_used $BRICK_DEV ; then 
    format_device $BRICK_DEV
  else
    # dev is used but should I zap it?
    if [ "${ZAP_DEV}" == "true" ]; then
      echo "- current disk configuration flagged to be wiped (ZapDevice=true)"
      
      # determine if the device belongs to lvm
      local vg_name=$(pvs $BRICK_DEV --noheadings -o vg_name | sed 's/\ //g')
      if [ $? -eq 0 ]; then 
        # pv worked, grab the vgname and drop the whole vg and pv
        vgremove -f $vg_name 1> /dev/null && pvremove $BRICK_DEV 1> /dev/null
        local wipe_rc=$?
        
      else
        # device is not a lvm2 disk, so try a 'wipefs' 
        wipefs -a $BRICK_DEV &> /dev/null      
        local wipe_rc=$?
      fi 
      
      if [ $wipe_rc -eq 0 ]; then 
        echo "- zap successful"
        format_device $BRICK_DEV
      else
        echo "- zap failed unable wipe $BRICK_DEV"
        exit 1
      fi
    else
      echo " - ${BRICK_DEV} is already defined and etcd config did NOT"
      echo "   request the device to be wiped"
    fi
  fi
    
}

function prep_ip {
  echo -e "\nPreparing this host for IP address $NODE_IP"
  # if the IP is already on this host do nothing
  # else add it!
  
  if IP_OK $NODE_IP; then
    echo "- $NODE_IP already active on this host, nothing to do"
  else
    echo "- Adding $NODE_IP to host's network"
    ip addr add $NODE_IP/24 dev eth0
    echo -e "IPADDR2=$NODE_IP\nNETMASK2=$NETMASK" \
         >> /etc/sysconfig/network-scripts/ifcfg-eth0
    echo 
  fi
  
}

echo -e "\nChecking configuration directories"
if [ ! -e /etc/glusterfs ] ; then 
  prep_directories
else 
  echo -e "- glusterfs directories already present, nothing to do"
fi

KV_IP=$(sed 's/\///g' /etc/kubernetes/config |\
        awk -F ":" '/KUBE_MASTER/ { print $2;}') 
        
echo -e "\nChecking for etcd service"
if [ $(etcd_ok) -eq 0 ]; then 
  echo -e "- etcd service found on ${KV_IP}"
  get_etcd_config
  
  if [ ! -z ${NODE_IP+x} ]; then
    prep_ip
  fi

  if [ ! -z ${BRICK_DEV+x} ]; then 
    prep_disk
  else
    echo -e "\nConfig does not provide any disk information, nothing to do"
  fi
  
else 
  echo -e "- etcd configuration is not available to automate the prep"
fi



