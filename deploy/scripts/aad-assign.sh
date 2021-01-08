#!/bin/bash

# -------------------------------------------------------------------------------
set -e
usage(){
    echo '
Usage: $0 
    --name                     Name of the identity or service principal
                               to create.
    --resourcegroup            Resource group if the identity is a managed
                               identity.  If omitted, identity will be a
                               service principal.
    --help                     Shows this help.
'
    exit 1
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
if [[ -z "$name" ]]; then echo "Parameter is empty or missing: --name"; usage; fi

if [[ -z "$resourcegroup" ]]; then
    # create or update identity and get service principal object id
    IFS=$'\n'; results=($(az ad sp create-for-rbac -n $name --role Contributor \
        --query '[appId, name, password, tenant]' -o tsv | tr -d '\r')); unset IFS;
    principalId=$(az ad sp show --id ${results[0]} --query objectId -o tsv | tr -d '\r')
else
    # create or update identity and get service principal object id
    principalId=$(az identity create -g $resourcegroup -n $name \
        --query principalId -o tsv | tr -d '\r')
fi
echo ""


# Get role with given name and assign it to the principal
assign_app_role(){
    appRoleId=$(az ad sp show --id $2 \
        --query "appRoles[?value=='$3'].id" -o tsv | tr -d '\r')
    if [[ -z "$appRoleId" ]]; then 
        echo "App role '$3' does not exist in '$2'."
        exit 1
    fi
    roleAssignmentId=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignments \
        --query "value[?appRoleId=='$appRoleId'].id" -o tsv | tr -d '\r')
    if [[ -z "$roleAssignmentId" ]]; then 
        roleAssignmentId=$(az rest --method post \
        --uri https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignments \
            --body '{ 
                "principalId": "'"$1"'", 
                "resourceId": "'"$2"'", 
                "appRoleId": "'"$appRoleId"'" 
            }' --query id -o tsv | tr -d '\r')
    fi
    echo "Assigned role '$3' ($appRoleId) to '$1' (assignment id: '$roleAssignmentId')"
}

# Assign app roles on graph API so principal can invoke graph methods. 
# We need the graph API principal id first.
graphSpId=$(az ad sp list --filter "DisplayName eq 'Microsoft Graph'" \
    --query [0].objectId -o tsv | tr -d '\r')
assign_app_role $principalId $graphSpId Application.ReadWrite.All
# ...

echo ""
if [[ -z "$resourcegroup" ]]; then
    # return the credential
    echo "Service principal created:"
    echo "    Name: ${results[1]}"
    echo "Password: ${results[2]}"
    echo "  Tenant: ${results[3]}"
else
    # return identity resource id to use in deployment
    echo "Managed identity created:"
    az identity show -g $resourcegroup -n $name --query "id" -o tsv | tr -d '\r'
fi
# -------------------------------------------------------------------------------



