#!/bin/bash

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

function log_msg {
  #
  # Write msgs to stdout, making them available to "docker logs"
  #
  
  local now=$(date +'%b %e %T')
  local logger=$(basename "$0")
  local host_name=$(printf "%-12s" $(hostname -s))
  printf "${now} ${host_name} [${logger}] $1\n"
}

function join { 
	local IFS="$1"
	shift 
	echo "$*"
}
