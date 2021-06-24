#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --resourcegroup, -g        Resource group in which the iot hub resides.
    --subscription, -s         Subscription where the resource group or 
                               iot hub was created.  If not set uses
                               the default subscription for the account.
    --hub, -h                  The iot hub to get edge information from.
                               (Default: first hub in resource group)
    --help                     Shows this help.
'
    exit 1
}

name=
iothubname=
subscription=
resourcegroup=
connectionstring=
unmanaged="null"

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name|-n)             name="$2"; shift ;;
        --hub|-h)              iothubname="$2"; shift ;;
        --resourcegroup|-g)    resourcegroup="$2"; shift ;;
        --connectionstring|-c) connectionstring="$2"; shift ;;
        --subscription|-s)     subscription="$2"; shift ;;
        --unmanaged)           unmanaged="true" ;;
        *)                     usage ;;
    esac
    shift
done

if ! az --version > /dev/null 2>&1 ; then
    # must be run as sudo to install azure cli
    if [ $EUID -ne 0 ]; then
        echo "$0 is not run as root, but required to install packages."
        exit 2
    fi
    apt-get update
    apt-get install ca-certificates curl apt-transport-https lsb-release gnupg
    curl -sL https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor |
        sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
    repo=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $repo main" |
        sudo tee /etc/apt/sources.list.d/azure-cli.list
    apt-get update
    apt-get install azure-cli
fi

if [[ -z "$connectionstring" ]] ; then
    if [[ -n "$subscription" ]] ; then
        az account set --subscription $subscription > /dev/null 2>&1
    fi

    if [[ -z "$iothubname" ]] ; then
        if [[ -z "$resourcegroup" ]] ; then
            echo "Must provide name of iot hub or resourcegroup name!"
            usage
        fi
        iothubname=$(az iot hub list -g $resourcegroup \
            --query [0].name -o tsv | tr -d '\r')
        if [[ -z "$iothubname" ]]; then
            echo "ERROR: Unable to determine iot hub name."
            echo "ERROR: Ensure one was created in resource group $resourcegroup."
            exit 1
        fi
    fi
    
    if [[ -z "$name" ]] ; then
        name=$(hostname | tr -s '/' '_')
        echo "Using $name as name of the gateway."
    fi

    # Create
    az iot hub device-identity create \
        --device-id $name --hub-name $iothubname --edge-enabled > /dev/null 2>&1
    if ! az iot hub device-twin update \
        --device-id $name --hub-name $iothubname --tags '{
            "__type__": "iiotedge",
            "os": "Linux",
            "unmanaged": '"$unmanaged"'
        }' > /dev/null 2>&1 ; then
        echo "ERROR: Unable to patch device $name."
        exit 1
    fi
    connectionstring=$(az iot hub device-identity connection-string show \
        --device-id $name --hub-name $iothubname --query "connectionString" \
        -o tsv | tr -d '\r')
    if [ $? -ne 0 ] || [[ -z "$connectionstring" ]]; then
        echo "ERROR: Unable to get connection string for $name."
        exit 1
    fi
fi
