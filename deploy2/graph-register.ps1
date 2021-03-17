<#
 .SYNOPSIS
  Registers required applications.

 .DESCRIPTION
  Registers the required applications in AAD and returns an object 
  containing the information.

 .PARAMETER Name
  The Name prefix under which to register the applications.

 .PARAMETER ReplyUrl
  A reply_url to register, e.g. https://<NAME>.azurewebsites.net/

 .PARAMETER SignInAudience
  The Sign In Audience to use (default: AzureADMyOrg)

 .PARAMETER EnvironmentName
  Azure cloud to use - defaults to Global cloud.

 .PARAMETER TenantId
  The Azure Active Directory tenant to use.
   
 .PARAMETER Context
  An existing Azure connectivity context to use instead of connecting.
  If provided, overrides the provided environment name or tenant id.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Name,
    [string] $ReplyUrl = $null,
    [string] $TenantId = $null,
    [string] $EnvironmentName = "AzureCloud", 
    [string] $SignInAudience = "AzureADMyOrg",
    [object] $Context = $null, 
    [string] $Output = $null,
    [switch] $AsJson
)

# -------------------------------------------------------------------------------
Import-Module Az 
Import-Module Microsoft.Graph.Authentication 
Import-Module Microsoft.Graph.Applications 
$script:ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
Remove-Module pwsh-setup -ErrorAction SilentlyContinue
Import-Module $(join-path $script:ScriptDir pwsh-setup.psm1)
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------------
# Log into azure
if (!$script:Context) {
    $script:Context = Connect-ToAzure -EnvironmentName $script:EnvironmentName `
        -TenantId $script:TenantId
}
$script:TenantId = $script:Context.Tenant.Id
$script:EnvironmentName = $script:Context.Environment.Name

# get a default access token from azure connection for graph
$accessToken = Get-AzAccessToken -TenantId $script:TenantId `
    -AzContext $script:Context `
    -ResourceUrl "https://graph.microsoft.com"
if (!$accessToken) {
    throw "Failed to get access token for Microsoft Graph."
}
$script:TenantId = $accessToken.TenantId
Connect-MgGraph -AccessToken $accessToken.Token -TenantId $script:TenantId 1>$null
#Connect-MgGraph -Scopes "Application.ReadWrite.All" -TenantId $script:TenantId

# ---------- client app ---------------------------------------------------------
$client = Get-MgApplication -Filter "DisplayName eq '$script:Name-client'" `
    -ErrorAction SilentlyContinue
if (!$client) {
    $client = New-MgApplication -DisplayName "$script:Name-client" `
        -SignInAudience $script:SignInAudience
    Write-Host "'$script:Name-client' registered in graph as $($client.Id)..."
}
else {
    Write-Host "'$script:Name-client' found in graph as $($client.Id)..."
}

# ---------- web app ------------------------------------------------------------
$webapp = Get-MgApplication -Filter "DisplayName eq '$script:Name-web'" `
    -ErrorAction SilentlyContinue
if (!$webapp) {
    $webapp = New-MgApplication -DisplayName "$script:Name-web" `
        -SignInAudience $script:SignInAudience
    Write-Host "'$script:Name-web' registered in graph as $($webapp.Id)..."
}
else {
    Write-Host "'$script:Name-web' found in graph as $($webapp.Id)..."
}

# ---------- service ------------------------------------------------------------
$user_impersonationScopeId = "be8ef2cb-ee19-4f25-bc45-e2d27aac303b"
$service = Get-MgApplication -Filter "DisplayName eq '$script:Name-service'" `
    -ErrorAction SilentlyContinue
if (!$service) {
    $service = New-MgApplication -DisplayName "$script:Name-service" `
        -SignInAudience $script:SignInAudience `
        -Api @{
            Oauth2PermissionScopes = @(
                [Microsoft.Graph.PowerShell.Models.MicrosoftGraphPermissionScope] @{
                    AdminConsentDescription = `
"Allow the application to access '$script:Name' on behalf of the signed-in user."
                    AdminConsentDisplayName = "Access $script:Name"
                    Id                      = $user_impersonationScopeId
                    IsEnabled               = $true
                    Type                    = "User"
                    UserConsentDescription  = `
"Allow the application to access '$script:Name' on your behalf."
                    UserConsentDisplayName  = "Access $script:Name"
                    Value                   = "user_impersonation"
                }
            )
        }
    Write-Host "'$script:Name-service' registered in graph as $($service.Id)..."
}
else {
    Write-Host "'$script:Name-service' found in graph as $($service.Id)..."
}

# ---------- update web app -----------------------------------------------------
$redirectUris = @(
    "urn:ietf:wg:oauth:2.0:oob"
    "https://localhost"
    "http://localhost"
)
# See if this script is called to update the webapp reply urls
$redirectUri = $script:ReplyUrl
if (![string]::IsNullOrEmpty($redirectUri)) {
    # Append "/" if necessary.
    $redirectUri = If ($redirectUri.Substring($redirectUri.Length - 1, 1) -eq "/") { $redirectUri } `
        Else { $redirectUri + "/" }
    $redirectUris += "$($redirectUri)signin-oidc"
    Write-Host "Registering $($redirectUri) as reply URL ..."
}
Update-MgApplication -ApplicationId $webapp.Id `
    -Web @{
        RedirectUris = $redirectUris
    } `
    -RequiredResourceAccess @{
        ResourceAccess = @(
            [Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess] @{ 
                Id = $user_impersonationScopeId
                Type = "Scope" 
            }
        )
        ResourceAppId  = $service.AppId
    }

if (![string]::IsNullOrEmpty($redirectUri)) {
    Write-Host "Reply urls registered on '$script:Name-web'."
    return
}
# add webapp secret
$webappAppSecret = $(Add-MgApplicationPassword -ApplicationId $webapp.Id).SecretText
$webapp = Get-MgApplication -ApplicationId $webapp.Id
Write-Host "'$script:Name-web' updated..."

# ---------- update client app --------------------------------------------------
Update-MgApplication -ApplicationId $client.Id `
    -IsFallbackPublicClient `
    -PublicClient @{
        RedirectUris = $redirectUris
    } `
    -RequiredResourceAccess @{
        ResourceAccess = @(
            [Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess] @{ 
                Id = $user_impersonationScopeId
                Type = "Scope" 
            }
        )
        ResourceAppId = $service.AppId
    }
$client = Get-MgApplication -ApplicationId $client.Id
Write-Host "'$script:Name-client' updated..."

# ---------- update service app -------------------------------------------------

# Add 1) Azure CLI and 2) Visual Studio to allow login the platform as clients
$knownApplications = @(
    $client.AppId
    $webapp.AppId
    "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
    "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"
)
$preauthorizedApplications = @( )
foreach ($appId in $knownApplications) {
    $preauthorizedApplications += `
    [Microsoft.Graph.PowerShell.Models.MicrosoftGraphPreAuthorizedApplication] @{
        AppId = $appId
        DelegatedPermissionIds = @($service.Api.Oauth2PermissionScopes.Id)
    }
}
Update-MgApplication -ApplicationId $service.Id `
    -IdentifierUris "https://$($service.PublisherDomain)/$($script:Name)-service" `
    -Api @{
        RequestedAccessTokenVersion = $null
        KnownClientApplications = $knownApplications
        PreAuthorizedApplications = $preauthorizedApplications
    }

# add service secret
$serviceAppSecret = $(Add-MgApplicationPassword -ApplicationId $service.Id).SecretText
$service = Get-MgApplication -ApplicationId $service.Id
Write-Host "'$script:Name-service' updated..."

# ---------- Admin consent ------------------------------------------------------
# Not needed since we only require user_impersonation
# try {
#     $graphSp = Get-MgServicePrincipal -Filter "DisplayName eq 'Microsoft Graph'" `
#         -ErrorAction SilentlyContinue    
#     New-MgOauth2PermissionGrant -ResourceId $graphSp.Id `
#         -ConsentType "AllPrincipals" `
#         -Scope "User.Read.All" -PrincipalId $null -ClientId $client.AppId
#     New-MgOauth2PermissionGrant -ResourceId $graphSp.Id `
#         -ConsentType "AllPrincipals" `
#         -Scope "User.Read.All" -PrincipalId $null -ClientId $webapp.AppId
# }
# catch {
#     # requires DelegatedPermissionGrant.ReadWrite.All, Directory.ReadWrite.All
#     Write-Warning `
# "Client applications couldn't be granted. This can be accomplished at first login."
# }

# ---------- Return results -----------------------------------------------------
$aadConfig = [pscustomobject] @{
    serviceAppId       = $service.AppId
    serviceAppSecret   = $serviceAppSecret
    serviceAudience    = $service.IdentifierUris[0].ToString()
    webappAppId        = $webapp.AppId
    webappAppSecret    = $webappAppSecret
    clientAppId        = $client.AppId
    tenantId           = $script:TenantId
    authorityUri       = $script:Context.Environment.ActiveDirectoryAuthority
    trustedTokenIssuer = "https://sts.windows.net/$($script:TenantId)"
}

if ($script:Output) {
    $aadConfig | ConvertTo-Json | Out-File $script:Output
    return
}
if ($script:AsJson.IsPresent) {
    return $aadConfig | ConvertTo-Json
}
return $aadConfig
# -------------------------------------------------------------------------------


