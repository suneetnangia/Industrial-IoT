#!/bin/bash

# -------------------------------------------------------------------------
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
    --subscription, -s         Subscription to create the resource group 
                               and managed identity in.  If not set uses
                               the default subscription for the account.

    --version, -v              Version to deploy
    --sourceuri, -u            Uri from where to deploy
    --dockerserver             Docker server
    --help                     Shows this help.
'
    exit 1
}

args=( "$@"  )
name=
resourcegroup=
location=
sourceuri=
version=
subscription=
dockerserver=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help)                usage ;;
        --name)                name="$2" ;;
        --resourcegroup)       resourcegroup="$2" ;;
        --subscription)        subscription="$2" ;;
        --location)            location="$2" ;;
        --sourceuri)           sourceuri="$2" ;;
        --dockerserver)        dockerserver="$2" ;;
        --version)             version="$2" ;;
        -n)                    name="$2" ;;
        -g)                    resourcegroup="$2" ;;
        -s)                    subscription="$2" ;;
        -l)                    location="$2" ;;
        -u)                    sourceuri="$2" ;;
        -v)                    version="$2" ;;
    esac
    shift
done

if [[ -z "$resourcegroup" ]]; then
    echo "Must specify resource group using --resourcegroup param."
    usage
fi
if [[ -z "$location" ]]; then
    echo "Must specify location using --location param."
    usage
fi

if [[ -z "$name" ]]; then
    name=$resourcegroup
fi
if [[ -z "$version" ]]; then
    version="preview"
fi
if [[ -z "$dockerserver" ]]; then
    dockerserver="industrialiotdev.azurecr.io"
fi

# -------------------------------------------------------------------------
if ! az account show > /dev/null 2>&1 ; then
    az login
fi
if [[ -n "$subscription" ]]; then 
    az account set -s $subscription
fi

# -------------------------------------------------------------------------
# updates subscription if id provided otherwise uses default
. create-sp.sh -n $name -g $resourcegroup -l $location > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create managed identity."
    exit 1
fi
aadPrincipalId=$(az identity show -g $resourcegroup -n $name \
    --query id -o tsv | tr -d '\r')

# get source uri   
if [[ -z "$sourceuri" ]]; then
    # create storage and upload the templates and scripts
    storage=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    storage="tempartifacts$storage"
    container="deploy"
    if ! az storage account create --sku Standard_LRS --kind Storage \
        -g $resourcegroup -l "$location" \
	-n "$storage" > /dev/null 2>&1 ; then
        echo "ERROR: Failed to create storage account $storage."
        exit 1
    fi
    cs=$(az storage account show-connection-string -n "$storage" \
        -g $resourcegroup --query connectionString -o tsv | tr -d '\r')
    if ! az storage container create --name $container \
        --public-access Off --connection-string $cs > /dev/null 2>&1 ; then
        echo "ERROR: Failed to create container $container in $storage."
        exit 1
    fi
    echo "Uploading deployment artifacts to storage..."
    if ! az storage copy --source templates --recursive \
        --destination https://$storage.blob.core.windows.net/$container \
	--connection-string $cs ; then
        echo "ERROR: Failed to upload artifacts to container $container"
        exit 1
    fi 
    expiretime=$(date -u -d '60 minutes' +%Y-%m-%dT%H:%MZ)
    token=$(az storage container generate-sas \
        -n $container --expiry $expiretime --permissions r \
        --connection-string $cs -o tsv | tr -d '\r')
    templateUrl=$(az storage blob url -c $container \
        -n templates/azuredeploy.json \
        --connection-string $cs -o tsv | tr -d '\r')
    templateUrlQueryString="?$token"
else
    templateUrl="$sourceuri/deploy2/templates/"
    templateUrlQueryString=""
    storage=
fi

echo '{
    "templateUrl": {
        "value": "'"$templateUrl"'"
    },
    "templateUrlQueryString": {
        "value": "'"$templateUrlQueryString"'"
    },
    "applicationName": {
        "value": "'"$name"'"
    },
    "aadPrincipalId": {
        "value": "'"$aadPrincipalId"'"
    },
    "deployPlatformComponents": {
        "value": false
    },
    "deployOptionalServices": {
        "value": false
    },
    "deployEngineeringTool": {
        "value": false
    },
    "helmPullChartFromDockerServer": {
        "value": false
    },
    "helmRepoUrl": {
        "value": "https://microsoft.github.io/charts/repo"
    },
    "helmChartName": {
        "value": "azure-industrial-iot"
    },
    "helmChartVersion": {
        "value": "0.4.0"
    },
    "imagesTag": {
        "value": "'"$version"'"
    },
    "dockerServer": {
        "value": "'"$dockerserver"'"
    },
    "tags": {
        "value": {
            "IoTSuiteType":  "AzureIndustrialIoT-AZ"
        }
    }
}' > deploy.json

# -------------------------------------------------------------------------
echo "Deploying..."
az deployment group create -g $resourcegroup \
    --template-uri $templateUrl?$token \
    --parameters @deploy.json
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to deploy."
fi
# delete the resource group and deployment parameter file.
if [[ -n "$storage" ]] ; then
    echo "Removing artifacts storage..."
    az storage account delete -g $resourcegroup -n $storage -y \
    	> /dev/null 2>&1
fi
rm -f deploy.json > /dev/null 2>&1
# -------------------------------------------------------------------------
