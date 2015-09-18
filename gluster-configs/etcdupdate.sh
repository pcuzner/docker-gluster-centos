#!/usr/bin/bash
#
# etcdupdate installs the config files into the etcd instance
# Run this on the kubernetes master node. If invoked with -p, we assume 
# the next value is the IP of the etcd node, and use that in the etcdctl
# command. If -p is not used the command defaults to trying localhost
#

peer_string=""

MODE=''

function load_config {
  # load the file(s) into etcd
  echo "Loading ${#FILES[@]} configuration files into etcd"
  for config in ${FILES[@]}; do 
    local key=$(grep '"HostName"' $config | sed 's/[",]//g' | awk '{print $2;}')
    if [ "$key" != "" ]; then 
      echo "- Adding config for host ${key} to gluster/config/${key}"
      etcdctl ${PEER_STRING} set gluster/config/${key} "$(cat $config)" 1> /dev/null
    else
      echo "- ERROR parsing $config - HostName attribute is missing"
    fi
  done
}

function usage {
  # show help
  echo -e "\netcdupdate.sh -h -d <directory> -f <file>"
  echo -e "Purpose: Upload gluster configurations to etcd"
  echo -e "-h ........ usage information"
  echo -e "-d <dir> .. upload all the *.json files in the given directory"
  echo -e "-f <file> . upload a specific file to etcd"
  echo -e "\nNB. This script should be run on the kubernetes master"
}

function die {
  # quit with error message
  echo $1
  exit 1
}

while getopts ":p:hf:d:" opt; do
  case $opt in

    d ) 
      [ "${OPTARG}" == "." ] && DIRNAME=$(pwd) || DIRNAME=${OPTARG}
      echo "Requesting a directory upload of ${DIRNAME}"
      [ "$MODE" == "file" ] && die "ERROR: -d and -f are mutually exclusive parameters"
      FILES=($(ls $DIRNAME/*.json))
      MODE='dir'
      ;;
    f ) 
      echo "Uploading a specific file '${OPTARG}' to etcd"
      [ "$MODE" == "dir" ] && die "ERROR : -d and -f are mutually exclusive parameters"
      if [ -e "$OPTARG" ]; then 
        FILES=($OPTARG)
      else
        die "- Requested file can not be found"
      fi
      MODE='file'
      ;;
    h ) 
      usage
      exit 0
      ;;
    p )
      PEER_STRING="--peers ${OPTARG}"
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

if [ "$MODE" == "" ]; then
  FILES=($(ls ./*.json))
fi

load_config 



