#!/bin/bash -ex


usage(){
    echo "Usage: $0 --name <applicationname> --resourcegroup <resourcegroup>"
    exit 1
}

# Get role and assign to the managed identity service principal
assign_app_role(){
    appRoleId=$(az ad sp show --id $2 --query "appRoles[?value=='$3'].id" -o tsv | tr -d '\r')
    if [[ -z "$appRoleId" ]]; then echo "App role '$3' does not exist in '$2'."; exit 1; fi
    roleAssignmentId=$(az rest --method get --uri https://graph.microsoft.com/beta/servicePrincipals/$1/appRoleAssignments --query "value[?appRoleId=='$appRoleId'].id" -o tsv | tr -d '\r')
    if [[ -z "$roleAssignmentId" ]]; then 
        roleAssignmentId=$(az rest --method post --uri https://graph.microsoft.com/beta/servicePrincipals/$1/appRoleAssignments \
            --body '{ "principalId": "'"$1"'", "resourceId": "'"$2"'", "appRoleId": "'"$appRoleId"'" }' --query id -o tsv | tr -d '\r')
    fi
    echo "App role '$3' ($appRoleId) assigned to '$1' as '$roleAssignmentId'"
}

name=
resourcegroup=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)                  name="$2" ;;
        --resourcegroup)         resourcegroup="$2" ;;
    esac
    shift
done
if [[ -z "$resourcegroup" ]]; then echo "Parameter is empty or missing: --resourcegroup"; usage; fi
if [[ -z "$name" ]]; then echo "Parameter is empty or missing: --name"; usage; fi

# create or update identity and get service principal object id
objectId=$(az identity create -g $resourcegroup -n $name --query principalId -o tsv | tr -d '\r')
# get graph API service principal id
graphSpId=$(az ad sp list --filter "DisplayName eq 'Microsoft Graph'" --query [0].objectId -o tsv | tr -d '\r')

assign_app_role $objectId $graphSpId Application.ReadWrite.All
# ...


#roleTemplateId=cf1c38e5-3621-4004-a7cb-879624dced7c # Application developer role
#roleTemplateId=158c047a-c907-4556-b7ef-446551a6b5f7 # Cloud application admin role
#if [[ -z "$roleTemplateId" ]]; then echo "Parameter is empty or missing: --roleTemplateId"; exit 1; fi
# get access token for graph api
#accessToken=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv | tr -d '\r')
# delete existing identity member if it exists
#curl https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$roleTemplateId/members/$objectId/\$ref -X DELETE -H "Authorization: Bearer $accessToken"
# add identity as member of directory role
#curl https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$roleTemplateId/members/\$ref -X POST -d '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/'"$objectId"'"}' -H "Content-Type: application/json" -H "Authorization: Bearer $accessToken"

# return identity resource id to use in deployment

az identity show -g $resourcegroup -n $name --query "id" -o tsv | tr -d '\r'




