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
    --connectionstring, -c     Alternative connection string to use
    --name, -n                 The name of the edge gateway instance.
    --release                  The edge runtime osversion (default: lts)
    --interactive, -i          Run the gateway in interactive mode (bash)

    --device                   The edge device (rpi1, rpi2, rpi3).
                               (Default: rpi2)
    --os                       The edge device operating system distro.
                               (Default: raspbian)
    --version                  The edge device operating system osversion.
                               (Default: stretch)    
    --help                     Shows this help.
'
    exit 1
}

name=
iothubname=
subscription=
resourcegroup=
connectionstring=
osdistro=
osversion=
device=
release=
unmanaged="null"
interactive=

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name|-n)             name="$2"; shift ;;
        --hub|-h)              iothubname="$2"; shift ;;
        --resourcegroup|-g)    resourcegroup="$2"; shift ;;
        --subscription|-s)     subscription="$2"; shift ;;
        --connectionstring|-c) connectionstring="$2"; shift ;;
        --release)             release="$2"; shift ;;
        --unmanaged)           unmanaged="true" ;;
        --interactive|-i)      interactive=1 ;;
        --os)                  osdistro="$2"; shift ;;
        --version)             osversion="$2"; shift ;;
        --device)              device="$2"; shift ;;
        *)                     usage ;;
    esac
    shift
done

if [[ -z "$osdistro" ]] ; then
    osdistro="raspbian"
fi
if [[ -z "$osversion" ]] ; then
    osversion="stretch"
fi
if [[ -z "$device" ]] ; then
    device="rpi3"
fi
if [[ -z "$release" ]] || [[ "$release" -eq "lts" ]] ; then
    release="1.1.1"
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
        name=$(echo "$(hostname)_${release}_${osdistro}_${osversion}_${device}" \
            | tr -s '/' '_')
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

# -------------------------------------------------------------------------------

# build and run
imagetag="${release}_${device}"

if [[ $device = rpi* ]] ; then
    cd rpi
else 
    echo "Unknown device $device"
    exit 1
fi

docker buildx create --name mybuilder --use  > /dev/null 2>&1
echo "Building $device gateway image iotedge:$imagetag"
if ! docker buildx build --load --progress plain --platform linux/amd64 \
    --tag iotedge:$imagetag . ; then 
    echo "ERROR: Error building iotedge:$imagetag for $device gateway $name."
    exit 1
fi

docker rm -f $name > /dev/null 2>&1
echo "Running $release on $osdistro:$osversion ($device)."

if ! container=$(docker container create -it --name $name \
    -e connectionString="$connectionstring" iotedge:$imagetag) ; then
    echo "ERROR: Error creating iotedge:$imagetag as $device gateway $name."
    exit 1
fi

if [[ -n "$interactive" ]] ; then
    docker container start -at $container
    docker rm -f $container > /dev/null 2>&1
elif ! docker container start $container ; then
    echo "ERROR: Error starting iotedge:$imagetag as $device gateway $name."
    exit 1
else
    echo "$name ($release on $device) running as $container."
fi

