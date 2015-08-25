#!/usr/bin/bash
#
# Prepare an Atomic host environment so it can offer a persistent
# gluster (or ceph?)  container
#

function show_usage {
  echo -e "Usage:"
  echo -e "  # prepHost.sh -t gluster\n"	
}


# accept a -t for type of storage container, and then call the relevant
# setup script to initialise the host
while getopts ":t:" opt; do

  case $opt in
    t )
      case $OPTARG in 
        gluster) 
          $(pwd)/prepGluster.sh
          exit 0
          ;;
        *)
          echo "Invalid storage type requested: ${OPTARG}" >&2
          exit 1        
          ;;
      esac
      ;;
    :)
      echo "Missing storage type"
      exit 1
      ;;
      
    \?)  
      echo "Invalid option: -$OPTARG" >&2
      exit 1        
      ;;
  esac
done

# If execution reaches this point the invocation was invalid!
show_usage
exit 1
