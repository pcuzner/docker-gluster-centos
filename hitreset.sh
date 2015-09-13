#!/usr/bin/bash

echo "removing directories"
rm -fr /etc/glusterfs
rm -fr /var/lib/glusterd
rm -fr /var/log/glusterfs

echo "removing disks"
pv=$(pvs -S vg_name=gluster -o pv_name --noheadings)
vgremove -f gluster
for dev in ${pv[@]}; do
  pvremove $dev
done

echo "removing IP config"
ip_alias=$(grep IPADDR2  /etc/sysconfig/network-scripts/ifcfg-eth0 | awk -F "=" '{print $2;}')
if [ -z ${ip_alias+x} ]; then
  echo "- no ip to remove"
else
  echo "- ip $ip_alias to remove"
  cp /etc/sysconfig/network-scripts/{ifcfg-eth0,eth0_backup}
  ip a del ${ip_alias}/24 dev eth0
  sed -i '/IPADDR2/d' /etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i '/NETMASK2/d' /etc/sysconfig/network-scripts/ifcfg-eth0
fi
