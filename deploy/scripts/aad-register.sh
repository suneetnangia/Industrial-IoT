#!/bin/bash -ex

usage(){
    echo "Usage: $0 register-service, unregister-service, register-client, unregister-client with with --name applicationname"
    exit 1
}

# Unregister service application in aad
unregister_service(){
    if [[ -z "$1" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Unregistering application '$1' from AAD tenant..."
    for objectId in $(az ad app list --display-name $applicationName --query [].objectId -o tsv | tr -d '\r'); do
        az ad app delete --id $objectId
        echo "Application '$objectId' unregistered from AAD tenant."
    done
}

# Register service application in aad using application developer role permissions (can create, not update)
register_service(){
    if [[ -z "$1" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Registering application '$1' in AAD tenant..."
    pw=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
    tenantName=$(az ad app list --all --query [0].publisherDomain -o tsv | tr -d '\r')
    if [[ -z "$tenantName" ]] ; then
        tenantName=$(az ad app create --display-name "__delete_me_$1" --query publisherDomain -o tsv | tr -d '\r')
    fi
    objectId=$(az ad app create --display-name $1 --password $pw --identifier-uris https://$tenantName/$1 --homepage "https://localhost" --query objectId -o tsv | tr -d '\r')
    az ad app update --id $objectId --set publicClient=false 
    az ad app update --id $objectId --set knownClientApplications='["04b07795-8ddb-461a-bbee-02f9e1bf7b46", "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"]'
    # az ad app credential reset --id $objectId --append --password $pw -o none
    echo "Application '$objectId' registered in AAD tenant."
    az ad app show --id $objectId --query "{serviceAppId:appId, servicePrincipalId:objectId, serviceAppSecret:'$pw', serviceAudience:identifierUris[0]}" -o json | tee $AZ_SCRIPTS_OUTPUT_PATH
}

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then set -ex; az login --identity; fi

applicationName=

[ $# -eq 0 ] && usage
c="$1"
shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) applicationName="$2" ;;
    esac
    shift
done
[ "$c" == "register-service" ] && { register_service $applicationName; exit 0; }
[ "$c" == "unregister-service" ] && { unregister_service $applicationName; exit 0; }
usage
