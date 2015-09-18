# docker-gluster-centos
Repo containing dockerfiles and code used to run glusterfs on centos7 as a docker image

##Overview
Typically persistent storage within a container environment will involve multiple layers - one for compute, the other for storage. So what if we could collapse that architecture down to run a storage provider along side the containers themselves? Easier deployment, reduced costs and the same management engine for compute and storage..sounds interesting.

To that end, this project is exploring various ways to run glusterfs as a container on docker. glusterfs is a scaleout network filesystem that supports multiple protocols that could be utilised by containers; NFS, glusterfs native client and Swift. More protocols = increased flexibility for applications :)

Incorporating storage alongside your applications also presents some challenges - specifically around resource sharing. So what I've been thinking about is an architecture that designates nodes within the cluster as 'homes' for the glusterfs containers. This 'pinning' approach has the benefit of eliminating the resource overheads involved with copying data from 'A' to 'B', if a container is scheduled/rescheduled to another physcial node. Each time the container starts, I want it to start on the same physical host - no data recovery or healing.

At this stage, the project supports running a glusterfs cluster in two ways;  
1. under an overlay network such as flannel, where each gluster peer will use a dynamic IP address  
2. using static IP's, binding the glusterfs container to the host's networking stack  

Option 2 aligns to the 'binding gluster to a host' strategy, so let's explore how you can use this project to run containerized gluster to provide storage for your containers.

Now the caveat - this project is a work in progress, and serves as a proof of concept model not a production blueprint!


##Pre-requisites
Firstly, you should have a working kubernetes environment that has a minimum of 2 kubernetes nodes, and 1 kubernetes master. For my testing I used Atomic Host and followed the excellent startup guide from [Project Atomic](http://www.projectatomic.io/docs/gettingstarted/). Each kubernetes node should have a data drive (/dev/sda) free to be used as a glusterfs brick.  
  
To use static IP's, I'm currently using host based networking. This requires each docker host's kubelet defintion to allow host networking. To enable, update /etc/kubernetes/kubelet on each node with the following;  
`KUBELET_ARGS="--host-network-sources=*"` 

Due to the networking approach, and the desire to control storage we also need the kubelet on the hosts to support privileged mode containers. To enable, update /etc/kubernetes/config on each host with;  
`KUBE_ALLOW_PRIV="--allow-privileged=true"`

Almost there...next up grab the docker image for each of your containers.  
`# docker pull pcuzner/glusterfs-centos`  
(or build it locally from the dockerfile included in this repo)

##Configuration  
The goal that I had for this project was to centralize the configuration for the glusterfs cluster as much as possible. Since etcd is already running on the kube master, it seemed like a great place to store the desired configuration for glusterfs.  

###Setup etcd  
Within the repo, you'll find a *gluster-configs* directory. Each host should have a corresponding json file which governs how that host should be configured to support the glusterfs container. In the directory you'll see 4 examples, atomic-1.json -> atomic-4.json and the etcdupdate.sh script used to load the config into etcd.  

In this example, we'll just set up a 2 node cluster; gluster-1 on atomic-1 and gluster-2 on atomic-2. atomic-1's defintion looks like;  
```
{  
  "HostName": "atomic-1",  
  "GlusterNodeName": "gluster-1",  
  "IPAddress": "10.1.1.1/24",  
  "BrickDevice": "/dev/sda",  
  "ZapDevice": "true",  
  "PeerList": [    
    { "IP": "10.1.1.2" }  
  ]  
}
```  
Here's what we're doing;  
**IPAddress**     this is the static IP that will be added to the hosts bridge for the glusterfs container to bind to. One of the implications of this approach is that every cluster node that needs to access the glusterfs services will need to have an ip alias on the same subnet - in this example all nodes would need a 10.1.1.x alias.  
**BrickDevice**   the device name of the HDD on the node that we want to use as a glusterfs brick  
**PeerList**      the IP address(es) of the peer nodes that make up the glusterfs cluster  

These configuration defintions are used in two discrete phases - the prepartion of the host, and the bootstrap of the glusterfs container. To load the config into etcd we just call the etcdupdate.sh script  
```
# etcdupdate.sh -f atomic-1.json
# etcdupdate.sh -f atomic-2.json
```
you can confirm that the configuration is available by querying etcd directly  
`# etcdctl get gluster/config/atomic-1`  

###Prepare the Host(s)  
The hosts that will run the glusterfs container need to be prepared. Apart from the obvious docker pull for the image, you need to prep the network and the disk for the container to use. The repo has a `prepHost.sh` script for this purpose which you run on each host.  
`# ./prepHost.sh -t gluster`  
The script grabs the config from etcd, and preps the disk and network stack ready for the container to persist on that specific node. As well as the disk and network, the preparation also creates some directories on the host that will be passed through to the container e.g. /etc/glusterfs. Using host directories in this way ensures that each time the container starts it picks up where it left off, and in the event of problems the glusterfs logs will be available for diagnostics.     
example output  
```
-bash-4.3# ./prepHost.sh -t gluster

Checking configuration directories
- creating directories for glusterfs config and logging
- resetting SELINUX context on the glusterfs directories

Checking for etcd service
- etcd service found on kubernetes.storage.lab
- retrieving this hosts intended config from etcd

Preparing this host for IP address 10.1.1.1
- Adding 10.1.1.1 to host's network


Preparing /dev/sda for gluster use
- configuring /dev/sda with LVM
  Physical volume "/dev/sda" successfully created
  Volume group "gluster" successfully created
  Logical volume "brickpool" created.
  Logical volume "brick1" created.
- Creating XFS filesystem
- filesystem created successfully
```  
##Running the Container  
With the configuration in place, and the host prepared all that's left is to actually start the container.  
  
###Native docker execution
```
# docker run -d --net=host -e KV_IP=kubernetes --name=gluster-1 \  
        -v /etc/glusterfs:/etc/glusterfs -v /var/lib/glusterd:/var/lib/glusterd \
        -v /var/log/glusterfs:/var/log/glusterfs -v /dev/:/dev/ \
       --privileged pcuzner/glusterfs-centos
```  
The *environment variable* KV_IP is used by the container's bootstrap script to contact etcd and extract the relevat configuration for the executing host.  

###Using kubernetes  
Using docker natively is one thing, but using kubernetes to start you containers, monitor them and restart them if they fail is the more resilient (grown up!) option. Within the repo you'll find two 'yaml' files - these files define the [pods](http://kubernetes.io/v1.0/docs/user-guide/pods.html) that start up the glusterfs containers quickly and easily. The pod defintions pass the same parameters as the native invocation to docker, so functionally they are the same. To start the containers through kubernetes;  
```
# kubectl create -f gluster-1.yaml  
# kubectl create -f gluster-2.yaml  
# kubectl get pods
NAME        READY     REASON    RESTARTS   AGE
gluster-1   1/1       Running   0          3m
gluster-2   1/1       Running   0          2m
```  
With the pods active, you can check the logs of the containers from the kubernetes master    
```
-bash-4.3# kubectl logs gluster-1
Sep 18 03:26:34 atomic-1     [entrypoint.sh] Container started with --net=host
Sep 18 03:26:34 atomic-1     [entrypoint.sh] KV store at 'http://kubernetes' will be queried for container configuration
Sep 18 03:26:35 atomic-1     [entrypoint.sh] -> Gluster Node IP .... 10.1.1.1/24
Sep 18 03:26:36 atomic-1     [entrypoint.sh] -> Gluster Name ....... gluster-1
Sep 18 03:26:36 atomic-1     [entrypoint.sh] -> Peer List .......... 10.1.1.2
Sep 18 03:26:36 atomic-1     [entrypoint.sh] Seeding the configuration directories
Sep 18 03:26:36 atomic-1     [entrypoint.sh] checking 10.1.1.1 is available on this host
Sep 18 03:26:36 atomic-1     [entrypoint.sh] 10.1.1.1 is valid
Sep 18 03:26:36 atomic-1     [entrypoint.sh] Checking glusterd is only binding to 10.1.1.1
Sep 18 03:26:36 atomic-1     [entrypoint.sh] Updating glusterd to bind only to 10.1.1.1
Sep 18 03:26:36 atomic-1     [entrypoint.sh] Updating sshd to bind only to 10.1.1.1
Sep 18 03:26:36 atomic-1     [entrypoint.sh] Setting container hostname to gluster-1
Sep 18 03:26:37 gluster-1    [entrypoint.sh] Adding LV brick1 to fstab at /gluster/brick1
Sep 18 03:26:37 gluster-1    [entrypoint.sh] Mounting the brick(s) to this container
Sep 18 03:26:37 gluster-1    [entrypoint.sh] Existing peer node definitions have not been found
Sep 18 03:26:37 gluster-1    [entrypoint.sh] Using the list of peers from the etcd configuration
Sep 18 03:26:37 gluster-1    [entrypoint.sh] Forking the create_cluster process
Sep 18 03:26:37 gluster-1    [entrypoint.sh] Starting services
Sep 18 03:26:52 gluster-1    [create_cluster.sh] glusterd detected on 10.1.1.1
:
Sep 18 03:28:19 gluster-1    [create_cluster.sh] glusterd detected on 10.1.1.1
Sep 18 03:28:19 gluster-1    [create_cluster.sh] glusterd detected on 10.1.1.2
Sep 18 03:28:19 gluster-1    [create_cluster.sh] All nodes required are available, creating a trusted storage pool of 2 nodes
Sep 18 03:28:27 gluster-1    [create_cluster.sh] Added node 10.1.1.2 .... ( peer probe: success. )
Sep 18 03:28:27 gluster-1    [create_cluster.sh] All nodes requested added to the cluster successfully
```
##Managing glusterfs  
once the containers are started, the first invocation will attempt to automatically create the cluster for you based on the PeerList setting in the configuration file (as shown above). To login to the container(s), you can either login to the container via docker, kubernetes or use ssh directly to the containers IP (10.1.1.1 or 10.1.1.2).  
```
-bash-4.3# kubectl exec -it gluster-1 bash 
[root@gluster-1 /]# gluster pool list 
UUID					Hostname 	State
09e5a114-f651-49f3-a9b0-520ba863a3a7	10.1.1.2 	Connected 
37365201-f9bd-456c-b375-e073c92add03	localhost	Connected 
[root@gluster-1 /]# df -h 
Filesystem                  Size  Used Avail Use% Mounted on
/dev/dm-11                   10G  250M  9.8G   3% /
devtmpfs                    2.0G     0  2.0G   0% /dev
tmpfs                       2.0G     0  2.0G   0% /dev/shm
/dev/mapper/fedora-root      13G  1.8G   11G  15% /etc/hosts
/dev/mapper/gluster-brick1   45G   33M   45G   1% /gluster/brick1
tmpfs                       2.0G  8.4M  2.0G   1% /run
```
From this point on glusterfs behaves normally, so you can create a volume and present some capacity to other containers.
```
[root@gluster-1 ~]# gluster vol create replicated replica 2 10.1.1.1:/gluster/brick1/replicated 10.1.1.2:/gluster/brick1/replicated
volume create: replicated: success: please start the volume to access data
[root@gluster-1 ~]# gluster vol start replicated 
volume start: replicated: success
```
Now the cool thing is that when you're using kubernetes, if the container dies kubernetes restarts it again. Furthermore, since the config and logs are persisted AND the container is bound to a physical host, it restarts to the point where it left off.  

##Known Issues
1. Snapshots are not currently working on this image (2015/09). Currently investigating the issue.
2. Some gluster commands fail due to the container being bound to a specific IP. A [BZ](https://bugzilla.redhat.com/show_bug.cgi?id=1257343) is open for this issue.
