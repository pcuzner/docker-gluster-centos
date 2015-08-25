#!/bin/bash

function log_msg {
  #
  # Write msgs to stdout, making them available to "docker logs"
  #
  
  local now=$(date +'%b %e %T')
  local logger=$(basename "$0")
  local host_name=$(printf "%-12s" $(hostname -s))
  printf "${now} ${host_name} [${logger}] $1\n"
}

function port_open {
  return $(nc "$1" "$2" < /dev/null &> /dev/null; echo $?)
}

function empty_dir {
  # check whether a given directory is empty
  if [ "$(ls -A ${1}/* &> /dev/null; echo $?)" -gt 0 ]; then 
    return 0
  else
    return 1
  fi
}

function element_in {
  #
  # Checks whether a given string is in an array
  # Input: 2 parms, $1 = string to search for, $2 is the array to search
  #
  
  local element
  for element in "${@:2}"; do
  
    if [ "$element" == "$1" ]; then 
      return 0
    fi
    
  done
  
  return 1 
}


function join { 
	local IFS="$1"
	shift 
	echo "$*"
}

function IP_OK {
  #
  # check that the IP matches one of the IP's on the host machine
  #
  
  IFS=$'\n' IP_LIST=($(ip -4 -o addr | sed -e "s/\//\ /g"| awk '{print $4;}'))
  if element_in $1 ${IP_LIST[@]} ; then 
    return 0
  else
    return 1 
  fi
	
}
