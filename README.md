# docker-gluster-centos
Repo containing dockerfiles and code used to run glusterfs on centos7 as a docker image

##Overview
There are two ways that gluster can run within an Atomic environment

1. under an overlay network such as flannel, where each gluster peer will use a dynamic IP address  
2. using static IP's bond to the atomic host's networking stack

Using Static IP's
Static configurations are supported in one of two ways; IP configuration is provided on the docker run command, or the configuration for the gluster pool is stored in etcd and extracted by the containers bootstrap script.

This project is not complete - so please, feel free to contribute!  

##Pre-requisites
If the desired architecture for gluster is based on flannel networking, you need to update the docker and flanneld configuration on the atomic hosts to allow flannel to handle the ip masquerading function. To do this you need to update the following files on each atomic host

**/etc/sysconfig/docker**  
ensure the OPTIONS parameter inclues `--ip-masq=false`  
  
**/etc/sysconfig/flanneld**  
ensure the FLANNEL_OPTIONS parameter includes `-iface=<dev> -ip-masq=true`  
*where dev is the interface that the default gateway points to*

##Building the docker image

##Invocation examples

###etcd based example  

```
> docker run -d --net=host -e KV_IP=kubernetes --name=gluster-1 \  
       --privileged centos-gluster
``` 
###flannel based  
```
> docker run -d --name=gluster-3 -h gluster-3 --privileged centos-gluster  
``` 

