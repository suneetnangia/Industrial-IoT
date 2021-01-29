#!/bin/bash

# -------------------------------------------------------------------------------
if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then set -ex; else set -e; fi

usage(){
    echo '
Usage: '"$0"' 
                               Create an admin security group in the 
                               graph and add the owners, members, and 
                               principal to it, then output group
                               object id
    --user,                    Service principal id or msi 
                               if service principal then will also be
                               added as member.
        --password, --tenant   Logs into azure using service principal.
    --identity                 Logs into azure using managed identity.

    --name                     Create an admin security group with the
                               given short name.
    --display                  Optional Display name for the group.
    --description              Optional description for the group.

    --owner                    Optional owner principal id (multiple).
    --member                   Optional member principal id (multiple).
    --help                     Shows this help.
'
    exit 1
}

groupName=
description=
displayName=
login=
owners=( )
members=( )
groupId=
principalId=
tenantId=

#principalPassword - allow passing in environment
#config            - allow passing in environment

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)            groupName="$2" ;;
        --owner)           owners+="$2" ;;
        --member)          members+="$2" ;;
        --description)     description="$2" ;;
        --display)         displayName="$2" ;;
        --identity)        login="unattended" ;;
        --user)            principalId="$2" ;;
        --password)        principalPassword="$2" ;;
        --tenant)          tenantId="$2" ;;
        --groupid)         groupId="$2" ;;
        --help)            usage ;;
    esac
    shift
done

# ---------- Login --------------------------------------------------------------
# requires Group.ReadWrite.All permissions to graph
if [[ "$login" == "unattended" ]] ; then
    if [[ -n "$principalId" ]] ; then
        if ! az login --identity -u "$principalId" --allow-no-subscriptions; then
            echo "Failed to log in with managed identity '$principalId'."
            exit 1
        fi
    else
        if ! az login --identity --allow-no-subscriptions; then
            echo "Failed to log in with managed identity."
            exit 1
        fi
    fi
elif [[ -n "$principalId" ]] && \
     [[ -n "$principalPassword" ]] && \
     [[ -n "$tenantId" ]]; then
    if ! az login --service-principal -u $principalId \
        -p=$principalPassword -t $tenantId --allow-no-subscriptions; then
        echo "Failed to log in with service principal '$principalId'."
        exit 1
    fi
elif [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    echo "Must login with service principal or managed identity"
    exit 1
else
    ownerId=$(az ad signed-in-user show --query objectId -o tsv | tr -d '\r')
    if [[ -n "$ownerId" ]] ; then 
        owners+="$ownerId" 
    fi
fi

# ---------- Register -----------------------------------------------------------

# see https://docs.microsoft.com/en-us/graph/api/resources/group?view=graph-rest-1.0
if [[ -z "$groupId" ]] ; then
    if [[ -z "$groupName" ]] ; then 
        echo "Parameter is empty or missing: --name"; usage
    fi
    if [[ -z "$description" ]] ; then 
        description="Administrator group for the '"$groupName"' resource."
    fi
    if [[ -z "$displayName" ]] ; then 
        displayName="$groupName Administrators"
    fi
    
    # ---------- create ---------------------------------------------------------
    groupId=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/groups \
        --uri-parameters "\$filter=displayName eq '$displayName'" \
        --query value[0].id -o tsv | tr -d '\r')
    if [[ -z "$groupId" ]] ; then
        groupId=$(az rest --method post \
            --uri https://graph.microsoft.com/v1.0/groups \
            --headers Content-Type=application/json \
            --body '{ 
                "description": "'"$description"'",
                "displayName": "'"$displayName"'",
                "mailEnabled": false,
                "mailNickname": "'"$groupName"'",
                "groupTypes": [],
                "securityEnabled": true,
                "visibility": "Private"
            }' --query id -o tsv | tr -d '\r')
        echo "'$displayName' group registered in graph with id $groupId..."
    else
        echo "'$displayName' group found in graph with id $groupId..."
    fi
fi

# ---------- add owners and members ---------------------------------------------
# add reference to members or owners
add_group_ref(){
    # bug - need to use beta api since v1.0 does not return SP references
    existing=$(az rest --method get \
        --uri https://graph.microsoft.com/beta/groups/$1/$3 \
        --query "value[?id=='$2'].id" -o tsv | tr -d '\r')
    if [[ "$existing" == "$2" ]] ; then
        echo "'$2' already part of the $3 of group $1 ..."
    else
        az rest --method post \
            --uri https://graph.microsoft.com/v1.0/groups/$1/$3/\$ref \
            --headers Content-Type=application/json --body '{
"@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/'"$2"'"
        }'
        echo "Added '$2' to group $1 $3..."
    fi
}

for id in "${owners[@]}" ; do
    add_group_ref $groupId $id "owners"
done
if [[ -n "$principalId" ]] && \
   [[ -n "$principalPassword" ]] ; then
    members+="$principalId"
fi
for id in "${members[@]}" ; do
    add_group_ref $groupId $id "members"
done

# get display name
IFS=$'\n'; group=($(az rest --method get \
    --uri https://graph.microsoft.com/v1.0/groups/$groupId \
    --query "[displayName, id]" -o tsv | tr -d '\r')); unset IFS;
displayName=${group[0]}

# ---------- Return results -----------------------------------------------------
echo '
{
    "groupId": "'"$groupId"'",
    "groupName": "'"$displayName"'"
}' | tee $AZ_SCRIPTS_OUTPUT_PATH
# -------------------------------------------------------------------------------

















