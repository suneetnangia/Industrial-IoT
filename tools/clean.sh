#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'
    1. Run first on the subscription using the -c flag to clear all tags.
    2. Ask team to add the tag to items they want to keep.
    3. When done, run again with -y flag to remove all iuntagged groups.

    --subscription, -s         Subscription to clean up. If not set uses
                               the default subscription for the account.
    --clear, -c                Clear the DoNotDelete tag from all matched
                               groups.
             -y                Perform actual deletion.
    
    --prefix                   Match and delete everything with prefix.
    --help                     Shows this help.
'
    exit 1
}

args=( "$@"  )
subscription=
delete=
prefix=
cleartag=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --subscription|-s)     subscription="$2" ; shift ;;
        --clear|-c)            cleartag=1 ;;
        --prefix)              prefix="$2" ; shift ;;
        -y)                    delete=1 ;;
        *)                     usage ;;
    esac
    shift
done

# -------------------------------------------------------------------------------
if ! az account show > /dev/null 2>&1 ; then
    az login
fi
if [[ -n "$subscription" ]]; then 
    az account set -s $subscription
fi

if [[ -n "$prefix" ]] ; then
    # select groups with prefix
    groups=$(az group list \
        --query "[?starts_with(name, '$prefix') && tags.Production!='true'].name" \
        -o tsv | tr -d '\r')
elif [[ -n "$cleartag" ]]; then
# select groups not marked for keeping
    groups=$(az group list \
        --query "[?tags.DoNotDelete=='true' && tags.Production!='true'].name" \
        -o tsv | tr -d '\r')
else
    # select groups not marked for keeping
    groups=$(az group list \
        --query "[?tags.DoNotDelete!='true' && tags.Production!='true'].name" \
        -o tsv | tr -d '\r')
fi

# remove groups 
for group in $groups; do
    if [[ -n "$cleartag" ]]; then
        echo "Clear DoNotDelete tag from resourcegroup $group ..."
        az group update -g $group --remove tags.DoNotDelete > /dev/null
    else
        if [[ $group = MC_* ]] ; then
            echo "skipping $group ..."
        elif [[ -z "$delete" ]]; then 
            echo "Would have deleted resourcegroup $group ..."
        else
            echo "Deleting resourcegroup $group ..."
            az group delete -g $group -y
        fi
    fi
done

# purge deleted keyvault
#for vault in $(az keyvault list-deleted -o tsv | tr -d '\r'); do
#    echo "deleting keyvault $vault ..."
#    az keyvault purge --name $vault
#done

