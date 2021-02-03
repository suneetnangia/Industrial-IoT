#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --namespace, -n            Namespace to use to install into.
    --resourcegroup, -g        Resource group in which the cluster resides.
    --help                     Shows this help.
'
    exit 1
}

# must be run as sudo
if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] && [ $EUID -ne 0 ]; then
    echo "$0 is not run as root. Try using sudo."
    exit 2
fi

CWD=$(pwd)
RESOURCE_GROUP=
AKS_CLUSTER=
ROLE=

#SERVICES_APP_SECRET= # allow passing from environment
#DOCKER_PASSWORD= # allow passing from environment

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help)                     usage ;;
        --resourcegroup)            RESOURCE_GROUP="$2" ;;
        -g)                         RESOURCE_GROUP="$2" ;;
        --cluster)                  AKS_CLUSTER="$2" ;;
        --role)                     ROLE="$2" ;;
    esac
    shift
done

# --------------------------------------------------------------------------------------

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    az login --identity
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "ERROR: Missing resource group name.  Use --resourcegroup parameter."
    usage
fi
if [[ -z "$AKS_CLUSTER" ]]; then
    AKS_CLUSTER=$(az aks list -g $RESOURCE_GROUP \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$AKS_CLUSTER" ]]; then
        echo "ERROR: Missing aks cluster name."
        echo "ERROR: Ensure one was created in resource group $RESOURCE_GROUP."
        exit 1
    fi
fi

# Go to home.
cd ~
if ! kubectl version > /dev/null 2>&1 ; then
    echo "Install kubectl..."
    if ! az aks install-cli > /dev/null 2>&1; then 
        echo "ERROR: Failed to install kubectl."
        exit 1
    fi
fi

# Get AKS credentials
if [[ "$ROLE" -eq "AzureKubernetesServiceClusterAdminRole" ]]; then
    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER --admin
else
    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER
fi

# install dashboard into the cluster
tag="v2.1.0" # v2.0.0, master, etc.
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/$tag/aio/deploy/recommended.yaml
url="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"

# start proxy and open browser
kubectl proxy &
sleep 1s
if ! x-www-browser $url ; then
    echo "Open $url to go to the dashboard"
fi
wait

# --------------------------------------------------------------------------------------
