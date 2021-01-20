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
    --sp,                      Service principal id - will also be member.
        --password, --tenant   Logs into azure using service principal.
    --identity                 Logs into azure using managed identity.

    --name                     Create an admin security group with the
                               given short name.
    --display                  Optional Display name for the group.
    --description              Optional description for the group.

    --owner                    Optional owner user id (principal id).
    --help                     Shows this help.
'
    exit 1
}

groupName=
groupDescription=
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
        --description)     groupDescription="$2" ;;
        --display)         displayName="$2" ;;
        --identity)        login="unattended" ;;
        --sp)              principalId="$2" ;;
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
    if ! az login --identity --allow-no-subscriptions; then
        echo "Failed to log in with managed identity."
        exit 1
    fi
elif [[ -n "$principalId" ]] && \
     [[ -n "$principalPassword" ]] && \
     [[ -n "$tenantId" ]]; then
    if ! az login --service-principal -u $principalId \
        -p=$principalPassword -t $tenantId --allow-no-subscriptions; then
        echo "Failed to log in with service principal."
        exit 1
    fi
elif [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    echo "Must login with service principal or managed identity"
    exit 1
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
    displayName="$groupName Administrators"
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

# ---------- add owners ---------------------------------------------------------
for id in "${owners[@]}" ; do
    body='{
"@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/{'"$id"'}"
    }' 
    az rest --method post \
        --uri https://graph.microsoft.com/v1.0/groups/$groupId/owners/$ref \
        --headers Content-Type=application/json --body $body > /dev/null 2>&1
    echo "Added '$id' to group $groupId as owner..."
done

# ---------- add members --------------------------------------------------------
if [[ -n "$principalId" ]]; then
    members+="$principalId"
fi
for id in "${members[@]}" ; do
    body='{
"@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/{'"$id"'}"
    }' 
    az rest --method post \
        --uri https://graph.microsoft.com/v1.0/groups/$groupId/members/$ref \
        --headers Content-Type=application/json --body $body > /dev/null 2>&1
    echo "Added '$id' to group $groupId as member..."
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

















