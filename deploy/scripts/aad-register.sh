#!/bin/bash -e

usage(){
    echo "Usage: $0 register-service, unregister-service, register-client, unregister-client with with --name applicationname"
    exit 1
}

# Register service application in aad
register_service(){
    if [[ -z "$applicationName" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Registering application '$applicationName' in AAD tenant..."
    objectId=$(az ad app create --display-name $applicationName --homepage "https://localhost" --query objectId -o tsv | tr -d '\r')
    pw=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32})
    tenantId=$(az ad app credential reset --id $objectId --append --password $pw --query tenant -o tsv | tr -d '\r')
    tenantName=$(az ad app show --id $objectId --query publisherDomain -o tsv | tr -d '\r')
    az ad app update --id $objectId --identifier-uris https://$tenantName/$applicationName \
        --set publicClient=false \
        --set knownClientApplications='["04b07795-8ddb-461a-bbee-02f9e1bf7b46", "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"]'
    az ad app show --id $objectId \
        --query "{serviceAppId:appId, serviceAppSecret:'$pw', serviceAudience:identifierUris[0], tenantId:'$tenantId'}" -o json \
        | tee $AZ_SCRIPTS_OUTPUT_PATH
}

# Unregister service application in aad
unregister_service(){
    if [[ -z "$applicationName" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Unregistering application '$applicationName' from AAD tenant..."
    for objectId in $(az ad app list --display-name $applicationName --query [].objectId -o tsv | tr -d '\r'); do
        az ad app delete --id $objectId
        echo "Application '$objectId' unregistered from AAD tenant..."
    done
}

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then set -x; az login --identity; fi

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
[ "$c" == "register-service" ] && { register_service; exit 0; }
[ "$c" == "unregister-service" ] && { unregister_service; exit 0; }
usage
