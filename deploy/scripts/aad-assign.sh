#!/bin/bash -ex

# Print usage
usage(){
    echo "Usage: $0 --name <applicationname> --resourcegroup <resourcegroup>"
    exit 1
}

# Get role and assign to the managed identity service principal
assign_app_role(){
    appRoleId=$(az ad sp show --id $2 --query "appRoles[?value=='$3'].id" -o tsv | tr -d '\r')
    if [[ -z "$appRoleId" ]]; then echo "App role '$3' does not exist in '$2'."; exit 1; fi
    roleAssignmentId=$(az rest --method get --uri https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignments --query "value[?appRoleId=='$appRoleId'].id" -o tsv | tr -d '\r')
    if [[ -z "$roleAssignmentId" ]]; then 
        roleAssignmentId=$(az rest --method post --uri https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignments \
            --body '{ "principalId": "'"$1"'", "resourceId": "'"$2"'", "appRoleId": "'"$appRoleId"'" }' --query id -o tsv | tr -d '\r')
    fi
    echo "App role '$3' ($appRoleId) assigned to '$1' as '$roleAssignmentId'"
}

# Assign directory role to the service principal
assign_directory_role(){
    az rest --method delete --uri https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$2/members/$1/\$ref > /dev/null 2>&1
    az rest --method post --uri https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$2/members/\$ref \
        --body '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/'"$1"'"}'
    echo "Directory role '$2' assigned to '$1'"
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

# Assign app roles on graph API so principal can invoke graph methods. We need the graph API principal id first.
graphSpId=$(az ad sp list --filter "DisplayName eq 'Microsoft Graph'" --query [0].objectId -o tsv | tr -d '\r')
assign_app_role $objectId $graphSpId Application.ReadWrite.All
# ...

# Assign principal to a directory role to give permissions to the directory.
# Using the guid as the name can change or be different from tenant to tenant while the template id is the same.
# Run az rest --method get --url https://graph.microsoft.com/v1.0/directoryRoles to get list of all role instances.
assign_directory_role $objectId cf1c38e5-3621-4004-a7cb-879624dced7c # Application developer role
# assign_directory_role $objectId 158c047a-c907-4556-b7ef-446551a6b5f7 # Cloud application admin role

# return identity resource id to use in deployment
az identity show -g $resourcegroup -n $name --query "id" -o tsv | tr -d '\r'




