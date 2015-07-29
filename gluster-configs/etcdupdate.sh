#!/usr/bin/bash
#
# etcdupdate installs the config files into the etcd instance
# Run this on the kubernetes master node
#

for config in  $(ls ./*.json); do
  filename=$(basename "$config")
  host_name="${filename%.*}"
  echo "Adding config for Atomic host ${host_name} to gluster/config/${host_name}"
  etcdctl set gluster/config/${host_name} "$(cat $config)" 1> /dev/null
done

