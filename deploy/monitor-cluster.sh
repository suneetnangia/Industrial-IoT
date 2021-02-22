#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --resourcegroup, -g        Resource group in which the cluster resides.

    --cluster, -n              (Optional) Cluster to use if more than one 
                               in the provided resource group.
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
resourcegroup=
aksCluster=
roleName=

#SERVICES_APP_SECRET= # allow passing from environment
#DOCKER_PASSWORD= # allow passing from environment

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help)                     usage ;;
        --resourcegroup)            resourcegroup="$2" ;;
        -g)                         resourcegroup="$2" ;;
        --cluster)                  aksCluster="$2" ;;
        --role)                     roleName="$2" ;;
    esac
    shift
done

# --------------------------------------------------------------------------------------

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    az login --identity
fi

if [[ -z "$resourcegroup" ]]; then
    echo "ERROR: Missing resource group name.  Use --resourcegroup parameter."
    usage
fi
if [[ -z "$aksCluster" ]]; then
    aksCluster=$(az aks list -g $resourcegroup \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$aksCluster" ]]; then
        echo "ERROR: Unable to determine aks cluster name."
        echo "ERROR: Ensure one was created in resource group $resourcegroup."
        exit 1
    fi
fi

# Go to home.
cd ~
if ! kubectl version --client > /dev/null 2>&1 ; then
    echo "Install kubectl..."
    if ! az aks install-cli ; then 
        echo "ERROR: Failed to install kubectl."
        exit 1
    fi
fi

# Get AKS credentials
if [[ "$roleName" -eq "AzureKubernetesServiceClusterUserRole" ]]; then
    az aks get-credentials --resource-group $resourcegroup \
        --name $aksCluster --admin
else
    az aks get-credentials --resource-group $resourcegroup \
        --name $aksCluster
fi

userId=$(az ad signed-in-user show --query objectId -o tsv | tr -d '\r')
if [[ -n "$userId" ]] ; then
    source $CWD/templates/scripts/group-setup.sh \
--description "Administrator group for $aksCluster in resource group $resourcegroup" \
        --display "$aksCluster Administrators" \
        --member "$userId" \
        --name "$aksCluster" 
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
