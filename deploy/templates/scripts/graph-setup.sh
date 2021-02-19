#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"' 
    --user,                    Service principal id or msi 
        --password, --tenant   Logs into azure using service principal.
    --identity                 Logs into azure using managed identity.

    --name                     Application name needed if configuration 
                               not provided (see --config).  The name is
                               used as display name prefix for all app
                               registrations and un-registrations.
        --serviceurl           Optional service url to register reply
                               urls.
        --clean                Unregister existing application 
                               registrations before registering.
        --unregister           Only perform un-registration.
        --owner                Optional owner user id (principal id).
        --audience             Optional audience - defaults to AzureADMyOrg.
         
    --config                   JSON configuration that has been generated
                               by a previous run or by aad-register.ps1. 
                               No registration (see --name) is performed 
                               when --config is provided. 
                               
    --keyvault                 Registration results or configuration is 
                               saved in keyvault if its name is specified. 
        --subscription         Subscription to use in which the keyvault
                               was created.  Default subscription is used 
                               if not provided.
        --msi                  Managed service identity to use to log
                               into the keyvault.
                               
    --help                     Shows this help.
'
    exit 1
}

applicationName=
keyVaultName=
keyVaultMsi=
subscription=
tenantId=
ownerId=
mode=
login=
principalId=
audience=
serviceurl=
#principalPassword - allow passing in environment
#config            - allow passing in environment

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)            applicationName="$2" ;;
        --keyvault)        keyVaultName="$2" ;;
        --msi)             keyVaultMsi="$2" ;;
        --subscription)    subscription="$2" ;;
        --clean)           mode="clean" ;;
        --unregister)      mode="unregisteronly" ;;
        --identity)        login="unattended" ;;
        --config)          config="$2" ;;
        --user)            principalId="$2" ;;
        --password)        principalPassword="$2" ;;
        --tenant)          tenantId="$2" ;;
        --audience)        audience="$2" ;;
        --owner)           ownerId="$2" ;;
        --serviceurl)      serviceurl="$2" ;;
        --help)            usage ;;
    esac
    shift
done

# ---------- Login --------------------------------------------------------------
# requires Application.ReadWrite.All permissions to graph
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
        echo "Failed to log in with service principal."
        exit 1
    fi
elif [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    echo "Must login with service principal or managed identity"
    exit 1
elif [[ -n "$ownerId" ]] ; then
    ownerId=$(az ad signed-in-user show --query objectId -o tsv | tr -d '\r')
fi

if [[ -z "$audience" ]] ; then
    audience="AzureADMyOrg"
fi
tenantId=$(az account show --query tenantId -o tsv | tr -d '\r')
trustedTokenIssuer="https://sts.windows.net/$tenantId"
authorityUri="https://login.microsoftonline.com"

# ---------- Unregister ---------------------------------------------------------
if [[ "$mode" == "unregisteronly" ]] || [[ "$mode" == "clean" ]] ; then
    if [[ -z "$applicationName" ]] ; then 
        echo "Parameter is empty or missing: --name"; usage
    fi
    for id in $(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications \
        --url-parameters "\$filter=startswith(displayName, '$applicationName-')" \
        --query "value[].id" -o tsv | tr -d '\r'); do
        appName=$(az rest --method get \
            --uri https://graph.microsoft.com/v1.0/applications/$id \
            --query displayName -o tsv | tr -d '\r')
        az rest --method delete \
            --uri https://graph.microsoft.com/v1.0/applications/$id
        echo "'$appName' ($id) unregistered from Graph."
    done
    if [[ "$mode" == "unregisteronly" ]] ; then
        exit 0
    fi
fi

# ---------- Register -----------------------------------------------------------
# see https://docs.microsoft.com/en-us/graph/api/resources/application?view=graph-rest-1.0
if [[ -z "$config" ]] || [[ "$config" == "{}" ]] ; then
    if [[ -z "$applicationName" ]] ; then 
        echo "Parameter is empty or missing: --name"; usage
    fi

    # ---------- client app -----------------------------------------------------
    clientId=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications \
        --uri-parameters "\$filter=displayName eq '$applicationName-client'" \
        --query value[0].id -o tsv | tr -d '\r')
    if [[ -z "$clientId" ]] ; then
        clientId=$(az rest --method post \
            --uri https://graph.microsoft.com/v1.0/applications \
            --headers Content-Type=application/json \
            --body '{ 
                "displayName": "'"$applicationName"'-client",
                "signInAudience": "'"$audience"'"
            }' --query id -o tsv | tr -d '\r')
        echo "'$applicationName-client' registered in graph as $clientId..."
    else
        echo "'$applicationName-client' found in graph as $clientId..."
    fi
    IFS=$'\n'; client=($(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications/$clientId \
        --query "[appId, publisherDomain, id]" -o tsv | tr -d '\r')); unset IFS;
    clientAppId=${client[0]}

    # ---------- web app --------------------------------------------------------
    webappId=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications \
        --uri-parameters "\$filter=displayName eq '$applicationName-web'" \
        --query value[0].id -o tsv | tr -d '\r')
    if [[ -z "$webappId" ]] ; then
        webappId=$(az rest --method post \
            --uri https://graph.microsoft.com/v1.0/applications \
            --headers Content-Type=application/json \
            --body '{ 
                "displayName": "'"$applicationName"'-web",
                "signInAudience": "'"$audience"'"
            }' --query id -o tsv | tr -d '\r')
        echo "'$applicationName-web' registered in graph as $webappId..."
    else
        echo "'$applicationName-web' found in graph as $webappId..."
    fi
    IFS=$'\n'; webapp=($(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications/$webappId \
        --query "[appId, publisherDomain, id]" -o tsv | tr -d '\r')); unset IFS;
    webappAppId=${webapp[0]}
  
    # ---------- service --------------------------------------------------------
    user_impersonationScopeId=be8ef2cb-ee19-4f25-bc45-e2d27aac303b
    serviceId=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications \
        --uri-parameters "\$filter=displayName eq '$applicationName-service'" \
        --query value[0].id -o tsv | tr -d '\r')
    if [[ -z "$serviceId" ]] ; then
        serviceId=$(az rest --method post \
            --uri https://graph.microsoft.com/v1.0/applications \
            --headers Content-Type=application/json \
            --body '{ 
                "displayName": "'"$applicationName"'-service",
                "signInAudience": "'"$audience"'",
                "api": {
                   "oauth2PermissionScopes": [ {
                       "adminConsentDescription": 
"Allow the application to access '"$applicationName"' on behalf of the signed-in user.",
                       "adminConsentDisplayName": "Access '"$applicationName"'",
                       "id": "'"$user_impersonationScopeId"'",
                       "isEnabled": true,
                       "type": "User",
                       "userConsentDescription": 
"Allow the application to access '"$applicationName"' on your behalf.",
                       "userConsentDisplayName": "Access'"$applicationName"'",
                       "value": "user_impersonation"
                   } ]
                }
            }' --query id -o tsv | tr -d '\r')
        echo "'$applicationName-service' registered in graph as $serviceId..."
    else
        echo "'$applicationName-service' found in graph as $serviceId..."
    fi
    permissionScopeIds=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications/$serviceId \
        --query "api.oauth2PermissionScopes[].id" -o json | tr -d '\r')
    IFS=$'\n'; service=($(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications/$serviceId \
        --query "[appId, publisherDomain, id]" -o tsv | tr -d '\r')); unset IFS;
    serviceAppId=${service[0]}

    # todo - require resource accss to all permission scopes

     # ---------- update owners -------------------------------------------------
    if [[ -n "$ownerId" ]] ; then
        # try and eat errors
        body='{
    "@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/'"$ownerId"'"
        }' 
        az rest --method post \
            --uri https://graph.microsoft.com/v1.0/applications/$serviceId/owners/\$ref \
            --headers Content-Type=application/json --body $body > /dev/null 2>&1
        az rest --method post \
            --uri https://graph.microsoft.com/v1.0/applications/$webappId/owners/\$ref \
            --headers Content-Type=application/json --body $body > /dev/null 2>&1
        az rest --method post \
            --uri https://graph.microsoft.com/v1.0/applications/$clientId/owners/\$ref \
            --headers Content-Type=application/json --body $body > /dev/null 2>&1
        echo "Owners updated..."
    fi

    # ---------- update client app ----------------------------------------------
    redirectUrls=(
        '"urn:ietf:wg:oauth:2.0:oob"'
        '"https://localhost"'
        '"http://localhost"'
    )
    jsonarray=$(IFS=$"," ; echo "${redirectUrls[*]}" ; unset IFS)
    az rest --method patch \
        --uri https://graph.microsoft.com/v1.0/applications/$clientId \
        --headers Content-Type=application/json \
        --body '{
            "isFallbackPublicClient": true,
            "publicClient": {
                "redirectUris": ['"$jsonarray"']
            },
            "requiredResourceAccess": [ {
              "resourceAccess": [ 
                {"id": "'"$user_impersonationScopeId"'", "type": "Scope" }
              ],
              "resourceAppId": "'"$serviceAppId"'"
            } ]
        }'
    echo "'$applicationName-client' updated..."

    # ---------- update web app -------------------------------------------------
    if [[ -z "$serviceurl" ]] ; then
        serviceurl="http://localhost:9080"
    fi
    if [[ ${serviceurl::7} != "http://" ]] && \
       [[ ${serviceurl::8} != "https://" ]] ; then
        serviceurl="https://$serviceurl"
    fi
    serviceurl=$(echo $serviceurl | sed 's/\/*$//g')
    redirectUrls=(
        '"urn:ietf:wg:oauth:2.0:oob"'
        '"'"$serviceurl"'/registry/swagger/oauth2-redirect.html"'
        '"'"$serviceurl"'/twin/swagger/oauth2-redirect.html"'
        '"'"$serviceurl"'/publisher/swagger/oauth2-redirect.html"'
        '"'"$serviceurl"'/events/swagger/oauth2-redirect.html"'
        '"'"$serviceurl"'/edge/publisher/swagger/oauth2-redirect.html"'
        '"'"$serviceurl"'/frontend/signin-oidc"'
    )
    jsonarray=$(IFS=$"," ; echo "${redirectUrls[*]}" ; unset IFS)
    az rest --method patch \
        --uri https://graph.microsoft.com/v1.0/applications/$webappId \
        --headers Content-Type=application/json \
        --body '{
            "isFallbackPublicClient": false,
            "web": {
                "implicitGrantSettings": {
                    "enableAccessTokenIssuance": false,
                    "enableIdTokenIssuance": true
                },
                "redirectUris": ['"$jsonarray"']
            },
            "requiredResourceAccess": [ {
              "resourceAccess": [ 
                {"id": "'"$user_impersonationScopeId"'", "type": "Scope" }
              ],
              "resourceAppId": "'"$serviceAppId"'"
            } ]
        }'
    # add webapp secret
    webappAppSecret=$(az rest --method post \
        --uri https://graph.microsoft.com/v1.0/applications/$webappId/addPassword \
        --headers Content-Type=application/json --body '{}' \
        --query secretText -o tsv | tr -d '\r')
    echo "'$applicationName-web' updated..."
        
    # ---------- update service app ---------------------------------------------
    # Add 1) Azure CLI and 2) Visual Studio to allow login the platform as clients
    az rest --method patch \
        --uri https://graph.microsoft.com/v1.0/applications/$serviceId \
        --headers Content-Type=application/json \
        --body '{
            "isFallbackPublicClient": false,
            "identifierUris": [ "'"https://${service[1]}/$applicationName-service"'" ],
            "api": {
                "requestedAccessTokenVersion": null,
                "knownClientApplications": [
                    "04b07795-8ddb-461a-bbee-02f9e1bf7b46", 
                    "872cd9fa-d31f-45e0-9eab-6e460a02d1f1",
                    "'"$clientAppId"'", "'"$webappAppId"'" ],
                "preAuthorizedApplications": [
                    {"appId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46", 
                        "delegatedPermissionIds": '"$permissionScopeIds"' },
                    {"appId": "872cd9fa-d31f-45e0-9eab-6e460a02d1f1",
                        "delegatedPermissionIds": '"$permissionScopeIds"' },
                    {"appId": "'"$clientAppId"'", 
                        "delegatedPermissionIds": '"$permissionScopeIds"' },
                    {"appId": "'"$webappAppId"'", 
                        "delegatedPermissionIds": '"$permissionScopeIds"' }
                ]
            }
        }'
       
    # add service secret
    serviceAppSecret=$(az rest --method post \
        --uri https://graph.microsoft.com/v1.0/applications/$serviceId/addPassword \
        --headers Content-Type=application/json --body '{}' \
        --query secretText -o tsv | tr -d '\r')
    echo "'$applicationName-service' updated..."

    serviceAudience=$(az rest --method get \
        --uri https://graph.microsoft.com/v1.0/applications/$serviceId \
        --query "[identifierUris[0]]" -o tsv | tr -d '\r')
else
    # parse config
              tenantId=$(jq -r ".tenantId? // empty" <<< $config)
    trustedTokenIssuer=$(jq -r ".trustedTokenIssuer? // empty" <<< $config)
          authorityUri=$(jq -r ".authorityUri? // empty" <<< $config)
          serviceAppId=$(jq -r ".serviceAppId? // empty" <<< $config)
      serviceAppSecret=$(jq -r ".serviceAppSecret? // empty" <<< $config)
       serviceAudience=$(jq -r ".serviceAudience? // empty" <<< $config)
           clientAppId=$(jq -r ".clientAppId? // empty" <<< $config)
           webappAppId=$(jq -r ".webappAppId? // empty" <<< $config)
       webappAppSecret=$(jq -r ".webappAppSecret? // empty" <<< $config)
fi
        
# ---------- Save results -------------------------------------------------------
if [[ -n "$keyVaultName" ]] ; then
    if [[ -n "$keyVaultMsi" ]] ; then
        if ! az login --identity -u "$keyVaultMsi" --allow-no-subscriptions; then
            echo "Failed to log in with managed identity '$keyVaultMsi'."
            exit 1
        fi
    fi

    # log in using the managed service identity and write secrets to keyvault
    if [[ -n "$subscription" ]] ; then
        az account set --subscription $subscription
    fi

    # try get current principal access to the keyvault
    rg=$(az keyvault show --name $keyVaultName \
        --query resourceGroup -o tsv | tr -d '\r')
    if [[ -n "$rg" ]] ; then
        rgid=$(az group show --name $rg --query id -o tsv | tr -d '\r')
        user=$(az ad signed-in-user show --query "objectId" -o tsv | tr -d '\r')
        if [[ -n "$user" ]] && [[ -n "$rgid" ]] ; then
            name=$(az role assignment create --assignee-object-id $user \
                --role b86a8fe4-44ce-4948-aee5-eccb2c155cd7 --scope $rgid \
                --query principalName -o tsv | tr -d '\r')
            echo "Assigned secret officer role to $name ($user) ..."
        fi 
    fi
    
    # there can be a delay in permissions or otherwise - retry
    while ! az keyvault secret set --vault-name $keyVaultName \
                     -n pcs-auth-required --value true 
    do 
        echo "... retry in 30 seconds..."
        sleep 30s; 
    done
                   
    az keyvault secret set --vault-name $keyVaultName \
                     -n pcs-auth-tenant --value "$tenantId"
    az keyvault secret set --vault-name $keyVaultName \
                     -n pcs-auth-issuer --value "$trustedTokenIssuer"
    az keyvault secret set --vault-name $keyVaultName \
                   -n pcs-auth-instance --value "$authorityUri"
    az keyvault secret set --vault-name $keyVaultName \
              -n pcs-auth-service-appid --value "$serviceAppId"
    az keyvault secret set --vault-name $keyVaultName \
             -n pcs-auth-service-secret --value "$serviceAppSecret"
    az keyvault secret set --vault-name $keyVaultName \
                   -n pcs-auth-audience --value "$serviceAudience"
    az keyvault secret set --vault-name $keyVaultName \
        -n pcs-auth-public-client-appid --value "$clientAppId"
    az keyvault secret set --vault-name $keyVaultName \
               -n pcs-auth-client-appid --value "$webappAppId"
    az keyvault secret set --vault-name $keyVaultName \
              -n pcs-auth-client-secret --value "$webappAppSecret"

    webappAppSecret=
    serviceAppSecret=
fi

# ---------- Return results -----------------------------------------------------
echo '
{
    "serviceAppId": "'"$serviceAppId"'",
    "serviceAppSecret": "'"$serviceAppSecret"'",
    "serviceAudience": "'"$serviceAudience"'",
    "webappAppId": "'"$webappAppId"'",
    "webappAppSecret": "'"$webappAppSecret"'",
    "clientAppId": "'"$clientAppId"'",
    "tenantId": "'"$tenantId"'",
    "trustedTokenIssuer": "'"$trustedTokenIssuer"'",
    "authorityUri": "'"$authorityUri"'"
}' | tee $AZ_SCRIPTS_OUTPUT_PATH
# -------------------------------------------------------------------------------

















