#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --name, -n                 Name of the identity or service principal
                               to create.
    --resourcegroup, -g        Resource group if the identity is a managed
                               identity.  If omitted, identity will be a
                               service principal.
    --location, -l             Location to create the group in if it does
                               not yet exist.
    --subscription, -s         Subscription to create the resource group 
                               and managed identity in.  If not set uses
                               the default subscription for the account.
    --help                     Shows this help.
'
    exit 1
}

name=
subscription=
resourcegroup=
location=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help)                usage ;;
        --name)                name="$2" ;;
        --resourcegroup)       resourcegroup="$2" ;;
        --subscription)        subscription="$2" ;;
        --location)            location="$2" ;;
        -n)                    name="$2" ;;
        -g)                    resourcegroup="$2" ;;
        -s)                    subscription=="$2" ;;
        -l)                    location="$2" ;;
    esac
    shift
done

# -------------------------------------------------------------------------------
if ! az account show > /dev/null 2>&1 ; then
    az login
fi

# -------------------------------------------------------------------------------
if [[ -z "$resourcegroup" ]]; then
    # create or update a service principal and get object id
    IFS=$'\n'
    if [[ -n "$name" ]]; then 
        results=($(az ad sp create-for-rbac -n $name --role Contributor \
            --query "[appId, name, password, tenant]" -o tsv | tr -d '\r'))
    else
        results=($(az ad sp create-for-rbac --role Contributor \
            --query "[appId, name, password, tenant]" -o tsv | tr -d '\r'))
    fi
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create service principal."
        exit 1
    fi
    unset IFS;
    principalId=$(az ad sp show --id ${results[0]} \
        --query objectId -o tsv | tr -d '\r')
else
    if [[ -z "$name" ]]; then 
        echo "Parameter is empty or missing: --name" >&2
        usage
    fi
    if [[ -n "$subscription" ]]; then 
        az account set -s $subscription
    fi
    rg=$(az group show -g $resourcegroup \
        --query id -o tsv 2> /dev/null | tr -d '\r')
    if [[ -z "$rg" ]]; then 
        if [[ -z "$location" ]]; then 
            echo "Parameter is empty or missing: --location" >&2
            usage
        fi
        rg=$(az group create -g $resourcegroup -l $location \
            --query id -o tsv | tr -d '\r')
    fi
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create resource group."
        exit 1
    fi
    # create or update identity and get service principal object id
    principalId=$(az identity show -g $resourcegroup -n $name \
        --query principalId -o tsv 2> /dev/null | tr -d '\r')
    if [[ -z "$principalId" ]]; then 
        principalId=$(az identity create -g $resourcegroup -n $name \
            --query principalId -o tsv | tr -d '\r')
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to create managed identity."
            exit 1
        fi
    fi
fi

# Get role with given name and assign it to the principal
assign_app_role(){
    appRoleId=$(az ad sp show --id $2 \
        --query "appRoles[?value=='$3'].id" -o tsv | tr -d '\r')
    if [[ -z "$appRoleId" ]]; then 
        echo "FATAL: App role '$3' does not exist in '$2'."
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
        if [[ -z "$roleAssignmentId" ]]; then 
            echo ""
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "Failed assigning role.  You likely do not have "
            echo "the consent to assign roles to Microsoft Graph."
            echo "The service principal cannot be used for Graph "
            echo "operations.!"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo ""
        else
            echo "Assigned role '$3' to '$1'." >&2
        fi
    fi
}

# Assign app roles on graph API so principal can invoke graph methods. 
# We need the graph API principal id first.
graphSpId=$(az ad sp list --filter "DisplayName eq 'Microsoft Graph'" \
    --query [0].objectId -o tsv | tr -d '\r')
if [[ -z "$graphSpId" ]]; then 
    echo "Unexpected: No Microsoft Graph service principal found."; exit 1
fi

assign_app_role $principalId $graphSpId Application.ReadWrite.All
assign_app_role $principalId $graphSpId Group.ReadWrite.All
# ...

echo ""
if [[ -z "$resourcegroup" ]]; then
echo '{
    "aadPrincipalId": "'"${results[1]}"'",
    "aadPrincipalPassword": "'"${results[2]}"'",
    "aadPrincipalTenantId": "'"${results[3]}"'"
}'
else
    results=($(az identity show -g $resourcegroup -n $name \
        --query "[id, tenantId]" -o tsv | tr -d '\r'))
echo '{
    "aadPrincipalId": "'"${results[0]}"'",
    "aadPrincipalTenantId": "'"${results[1]}"'"
}'
fi
# -------------------------------------------------------------------------------



