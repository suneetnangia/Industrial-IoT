#!/bin/bash -ex

roleTemplateId=cf1c38e5-3621-4004-a7cb-879624dced7c # Application developer role
# roleTemplateId=158c047a-c907-4556-b7ef-446551a6b5f7 # Cloud application admin role
name=
resourcegroup=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)                  name="$2" ;;
        --roleTemplateId)        roleTemplateId="$2" ;;
        --resourcegroup)         resourcegroup="$2" ;;
    esac
    shift
done
if [[ -z "$resourcegroup" ]]; then echo "Parameter is empty or missing: --resourcegroup"; exit 1; fi
if [[ -z "$name" ]]; then echo "Parameter is empty or missing: --name"; exit 1; fi
if [[ -z "$roleTemplateId" ]]; then echo "Parameter is empty or missing: --roleTemplateId"; exit 1; fi

# get access token for graph api
accessToken=$(az account get-access-token --resource-type ms-graph --query "accessToken" -o tsv | tr -d '\r')
# create or update identity
objectId=$(az identity create -g $resourcegroup -n $name --query "principalId" -o tsv | tr -d '\r')
# delete existing identity member if it exists
curl https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$roleTemplateId/members/$objectId/\$ref -X DELETE -H "Authorization: Bearer $accessToken"
# add identity as member of directory role
curl https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$roleTemplateId/members/\$ref -X POST -d '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/'"$objectId"'"}' -H "Content-Type: application/json" -H "Authorization: Bearer $accessToken"
# return identity resource id to use in deployment
az identity show -g $resourcegroup -n $name --query "id" -o tsv | tr -d '\r'




