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
        -s)                    subscription=="$2" ;;
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

# updates subscription if id provided otherwise uses default
. create-sp.sh -n "$name" -g "$resourceGroup" -l "$location" -s "$subscription"
aadPrincipalId=($(az identity show -g $resourcegroup -n $name \
    --query id -o tsv | tr -d '\r'))

if [[ -z "$sourceuri" ]]; then
    sourceuri = "https://raw.githubusercontent.com/Azure/Industrial-IoT/deployer"
fi
if [[ -z "$version" ]]; then
    version = "preview"
fi
if [[ -z "$dockerserver" ]]; then
    dockerserver = "industrialiotdev.azurecr.io"
fi

'{
    "templateUrl": {
        "value": "'"$sourceuri"'/deploy/templates/"
    },
    "applicationName": {
        "value": "'"$name"'"
    },
    "aadPrincipalId": {
        "value": "'"$aadPrincipalId"'"
    },
    "deployPlatformComponents": {
        "value": true
    },
    "deployOptionalServices": {
        "value": false
    },
    "imagesTag": {
        "value": "'"$version"'"
    },
    "scriptsUrl": {
        "value": "'"$sourceuri"'/deploy/scripts/"
    },
    "dockerServer": {
        "value": "'"$dockerserver"'"
    },
    "tags": {
        "value": {
            "IoTSuiteType":  "AzureIndustrialIoT-preview-AZ"
        }
    }
}' > deploy.json

echo "Deploying..."
az deployment group create -g $resourceGroup  \
    --template-uri $sourceuri/azuredeploy.json --parameters @deploy.json

