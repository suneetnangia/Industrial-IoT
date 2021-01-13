#!/bin/bash

# -------------------------------------------------------------------------------
set -e
usage(){
    echo '
Usage: '"$0"'  
    --name, -n                 Name of the identity or service principal
                               to create.
    --resourcegroup, -g        Resource group if the identity is a managed
                               identity.  If omitted, identity will be a
                               service principal.
    --location, -l             Location to create the group in if it does
                               not yet exist.
    --help                     Shows this help.
'
    exit 1
}

name=
resourcegroup=
location=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)                name="$2" ;;
        --resourcegroup)       resourcegroup="$2" ;;
        --location)            location="$2" ;;
        -n)                    name="$2" ;;
        -g)                    resourcegroup="$2" ;;
        -l)                    location="$2" ;;
    esac
    shift
done

jq . $(. create-sp.sh -n $name -g $resourceGroup -l $location)