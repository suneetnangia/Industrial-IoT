#!/bin/bash -ex

usage(){
    echo "Usage: $0 register-service, unregister-service, register-client, unregister-client with with --name applicationname"
    exit 1
}

# Register service application in aad
register_service(){
    if [[ -z "$1" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Registering application '$1' in AAD tenant..."
    
    tenantName=$(az account show --query name -o tsv | tr -d '\r')
    pw=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
    objectId=$(az ad app create --display-name $1 --identifier-uris https://$tenantName/$1 --password $pw --homepage "https://localhost" --query objectId -o tsv | tr -d '\r')

    echo "Application '$objectId' registered in AAD tenant."
    
    # Add 1) Azure CLI and 2) Visual Studio to allow log onto the platform with them as clients
    permissionIds=$(az ad app show --id $objectId --query "oauth2Permissions[].id" -o json | tr -d '\r')
    az rest --method patch --uri https://graph.microsoft.com/v1.0/applications/$objectId \
        --headers Content-Type=application/json \
        --body '{
            "api": {
                "knownClientApplications": ["04b07795-8ddb-461a-bbee-02f9e1bf7b46", "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"],
                "preAuthorizedApplications": [
                    {"appId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46", "delegatedPermissionIds": '"$permissionIds"' },
                    {"appId": "872cd9fa-d31f-45e0-9eab-6e460a02d1f1", "delegatedPermissionIds": '"$permissionIds"' }
                ]
            }                
        }'

    echo "Application '$objectId' updated with preauthorizations."
    az ad app show --id $objectId \
        --query "{serviceAppId:appId, servicePrincipalId:objectId, serviceAppSecret:'$pw', serviceAudience:identifierUris[0]}" -o json \
        | tee $AZ_SCRIPTS_OUTPUT_PATH
}

# Unregister service application in aad
unregister_service(){
    if [[ -z "$1" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Unregistering application '$1' from AAD tenant..."
    for objectId in $(az ad app list --display-name $1 --query [].objectId -o tsv | tr -d '\r'); do
        az ad app delete --id $objectId
        echo "Application '$objectId' unregistered from AAD tenant."
    done
}

applicationName=
msi=

[ $# -eq 0 ] && usage
c="$1"
shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --msi)      msi="$2" ;;
        --name)     applicationName="$2" ;;
    esac
    shift
done

if [[ -n "$msi" ]] ; then set -ex; az login --identity -u $msi; 
elif [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then set -ex; az login --identity; fi

[ "$c" == "register-service" ] && { register_service $applicationName; exit 0; }
[ "$c" == "unregister-service" ] && { unregister_service $applicationName; exit 0; }
usage
