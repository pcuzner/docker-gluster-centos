#!/usr/bin/bash
#
# etcdupdate installs the config files into the etcd instance
# Run this on the kubernetes master node. If invoked with -p, we assume the next value is the IP of the 
# etcd node, and use that in the etcdctl command. If -p is not used the command defaults to trying localhost
#

peer_string=""

while getopts ":p:" opt; do
  case $opt in
    p )
      peer_string="--peers ${OPTARG}:4001"
      echo "Using etcd peer IP of ${OPTARG}"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done


for config in  $(ls ./*.json); do
  filename=$(basename "$config")
  host_name="${filename%.*}"
  echo "- Adding config for host ${host_name} to gluster/config/${host_name}"
  etcdctl ${peer_string} set gluster/config/${host_name} "$(cat $config)" 1> /dev/null
done

