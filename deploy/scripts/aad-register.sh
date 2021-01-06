#!/bin/bash -ex

usage(){
    echo "Usage: $0 register, unregister with --name applicationname"
    exit 1
}

# Register applications in aad
register(){
    if [[ -z "$1" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    echo "Registering client application '$1' in AAD tenant..."
    replyUrls="urn:ietf:wg:oauth:2.0:oob https://localhost http://localhost"
    clientId=$(az ad app create --display-name $1-client true --reply-urls $replyUrls --query objectId -o tsv | tr -d '\r')
    clientAppId=$(az ad app show --id $clientId --query appId -o tsv | tr -d '\r')
    echo "Client Application '$clientId' registered in AAD tenant."

    echo "Registering service application '$1' in AAD tenant..."
    tenantName=$(az account show --query name -o tsv | tr -d '\r')
    pw=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
    serviceId=$(az ad app create --display-name $1-service --identifier-uris https://$tenantName/$1-service --password $pw --homepage "https://localhost" --query objectId -o tsv | tr -d '\r')
    echo "Service Application '$serviceId' registered in AAD tenant."
    
    # Add 1) Azure CLI and 2) Visual Studio to allow log onto the platform with them as clients
    permissionIds=$(az ad app show --id $serviceId --query "oauth2Permissions[].id" -o json | tr -d '\r')
    az rest --method patch --uri https://graph.microsoft.com/v1.0/applications/$serviceId \
        --headers Content-Type=application/json \
        --body '{
            "api": {
                "knownClientApplications": ["04b07795-8ddb-461a-bbee-02f9e1bf7b46", "872cd9fa-d31f-45e0-9eab-6e460a02d1f1", "'"$clientAppId"'" ],
                "preAuthorizedApplications": [
                    {"appId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46", "delegatedPermissionIds": '"$permissionIds"' },
                    {"appId": "872cd9fa-d31f-45e0-9eab-6e460a02d1f1", "delegatedPermissionIds": '"$permissionIds"' },
                    {"appId": "'"$clientAppId"'", "delegatedPermissionIds": '"$permissionIds"' }
                ]
            }                
        }'
    echo "Service Application '$serviceId' updated with preauthorizations."

    az ad app show --id $serviceId \
        --query "{serviceAppId:appId, serviceAppSecret:'$pw', serviceAudience:identifierUris[0], clientAppId:'$clientAppId' }" -o json \
        | tee $AZ_SCRIPTS_OUTPUT_PATH
}

# Unregister applications from aad
unregister(){
    if [[ -z "$1" ]] ; then echo "Parameter is empty or missing: --name"; usage; fi
    for id in $(az ad app list --display-name $1-client --query [].objectId -o tsv | tr -d '\r'); do
        az ad app delete --id $id; echo "Client Application '$id' unregistered from AAD tenant."
    done
    for id in $(az ad app list --display-name $1-service --query [].objectId -o tsv | tr -d '\r'); do
        az ad app delete --id $id; echo "Service Application '$id' unregistered from AAD tenant."
    done
}

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then set -ex; fi

applicationName=
serviceUrl=

[ $# -eq 0 ] && usage
c="$1"
shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)     applicationName="$2" ;;
    esac
    shift
done

if [[ -n "$principalId" ]] && [[ -n "$principalPassword" ]] && [[ -n "$principalTenant" ]] ; then az login -u $principalId -p=$principalPassword -t $principalTenant; 
elif [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then az login --identity; fi

[ "$c" == "register" ] && { register $applicationName; exit 0; }
[ "$c" == "unregister" ] && { unregister $applicationName; exit 0; }
usage
