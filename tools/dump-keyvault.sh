#!/bin/bash

# -------------------------------------------------------------------------------

usage(){
    echo '
Usage: '"$0"' 
    --resourcegroup, -g        Resource group in which the keyvault 
                               resides.
    --keyvault, n              The keyvault to get secrets from. 
    --subscription, -s         Subscription where the resource group or 
                               keyvault was created.  If not set uses
                               the default subscription for the account.
    --help                     Shows this help.
'
    exit 1
}

keyvaultname=
subscription=
resourcegroup=

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keyvault)            keyvaultname="$2" ;;
        --resourcegroup)       resourcegroup="$2" ;;
        --subscription)        subscription="$2" ;;
        -n)                    keyvaultname="$2" ;;
        -g)                    resourcegroup="$2" ;;
        -s)                    subscription="$2" ;;
        --help)                usage ;;
    esac
    shift
done

if [[ -n "$subscription" ]] ; then
    az account set --subscription $subscription
fi

if [[ -z "$keyvaultname" ]] ; then
    if [[ -z "$resourcegroup" ]] ; then
        echo "Must provide name of keyvault or resourcegroup name!"
        usage
    fi
    keyvaultname=$(az keyvault list -g $resourcegroup \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$keyvaultname" ]]; then
        echo "ERROR: Unable to determine keyvault name."
        echo "ERROR: Ensure one was created in resource group $resourcegroup."
        exit 1
    fi
fi

# try get access to the keyvault
resourcegroup=$(az keyvault show --name $keyvaultname \
    --query resourceGroup -o tsv | tr -d '\r')
if [[ -n "$resourcegroup" ]] ; then
    rgid=$(az group show --name $resourcegroup --query id -o tsv | tr -d '\r')
    user=$(az ad signed-in-user show --query "objectId" -o tsv | tr -d '\r')
    if [[ -n "$user" ]] && [[ -n "$rgid" ]] ; then
        name=$(az role assignment create --assignee-object-id $user \
            --role b86a8fe4-44ce-4948-aee5-eccb2c155cd7 --scope $rgid \
            --query principalName -o tsv | tr -d '\r')
        echo "Assigned secret officer role to $name ($user) scoped to '$resourcegroup'..."
    fi 
else
    echo "ERROR: Unable to determine resource group of keyvault."
    echo "ERROR: Ensure the keyvault $keyvaultname exists."
    exit 1
fi

# Wait for role assignment to complete
while ! secrets=$(az keyvault secret list --vault-name $keyvaultname \
    --query "[].id" -o tsv | tr -d '\r')
do 
    echo "... retry in 5 seconds..."
    sleep 5s; 
done

echo "Dumping contents of keyvault:"
echo ""
for id in $secrets; do 
    IFS=$'\n' 
    kv=($(az keyvault secret show --id $id \
        --query "[name, value]" -o tsv | tr -d '\r'))
    unset IFS
    echo "${kv[0]}=${kv[1]}"
done

