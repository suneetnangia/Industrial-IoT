<#
 .SYNOPSIS
    Creates a new service principal or managed identity.

 .DESCRIPTION
    Creates a new service principal or managed identity and assigns the 
    Microsoft Graph permission to create applications.

 .PARAMETER Name
    Name of the identity or service principal

 .PARAMETER ResourceGroup
    A resource group name if the identity is a managed identity. 
    If omitted, identity will be service principal.

 .PARAMETER Subscription
    Subscription id.
    If not provided and ambiguous user will be prompted for.

 .PARAMETER Location
    Location to create the resource group in if it does not yet exist.

 .PARAMETER EnvironmentName
    Azure cloud to use - defaults to Global cloud.

 .PARAMETER TenantId
    Tenant id to use.

 .PARAMETER Context
    An existing Azure connectivity context to use instead of connecting.
    If provided, overrides the provided Subscription, environment name
    or tenant id.
#>

param(
    [string] $Name = $null,
    [string] $ResourceGroup = $null,
    [string] $Location = $null,
    [string] $EnvironmentName = "AzureCloud", 
    [string] $Subscription = $null,
    [string] $TenantId = $null,
    [object] $Context = $null
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

$scripted=$($null -ne $script:Context)
if (!$scripted) {
    $script:Context = Connect-ToAzure -EnvironmentName $script:EnvironmentName `
        -SubscriptionId $script:Subscription -TenantId $script:TenantId
}

$script:Subscription = $script:Context.Subscription.Id
$script:TenantId = $script:Context.Tenant.Id
$script:EnvironmentName = $script:Context.Environment.Name

# get access token if profile provided
$accessToken = Get-AzAccessToken -TenantId $script:TenantId `
    -AzContext $script:Context `
    -ResourceUrl "https://graph.microsoft.com"
if (!$accessToken) {
    throw "Failed to get access token for Microsoft Graph."
}
$script:TenantId = $accessToken.TenantId
Connect-MgGraph -AccessToken $accessToken.Token -TenantId $script:TenantId 1>$null

# Get role with given name and assign it to the principal
Function Add-AppRole() {
    Param(
        [Parameter(Mandatory)][string] $principalId,
        [Parameter(Mandatory)][string] $appRoleName
    )
    $graphSp = Get-MgServicePrincipal -Filter "DisplayName eq 'Microsoft Graph'" `
        -ErrorAction SilentlyContinue
    if (!$graphSp) {
        throw "Unexpected: No Microsoft Graph service principal found."
    }
    $appRoleId = ($graphSp.AppRoles | Where-Object { $_.Value -eq $appRoleName }).Id
    if (!$graphSp) {
        throw "Unexpected: App role '$appRoleName' does not exist in '$($graphSp.Id)'."
    }
    # there is a delay to when the service principal is visible in the graph to assign to
    for ($a = 1; !$(Get-MgServicePrincipal -ServicePrincipalId $principalId `
        -ErrorAction SilentlyContinue); $a++) {
        if ($a -gt 5) {
            throw "Timeout: Service principal did not replicate to graph in time."
        }
        Write-Warning "Waiting for service principal creation..."
        Start-Sleep -Seconds 3 
    }
    $roleAssignment = Get-MgServicePrincipalAppRoleAssignment  `
        -ServicePrincipalId $principalId -ErrorAction SilentlyContinue `
        | Where-Object { $_.AppRoleId -eq $appRoleId }
    if (!$roleAssignment) {
        $roleAssignment = New-MgServicePrincipalAppRoleAssignment  `
            -ServicePrincipalId $principalId `
            -PrincipalId $principalId -AppRoleId $appRoleId -ResourceId $($graphSp.Id)
        if (!$roleAssignment) {
            Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Warning "Failed assigning role.  You likely do not have "
            Write-Warning "the necessary authorization to assign roles to "
            Write-Warning "Microsoft Graph."
            Write-Warning "The service principal cannot be used for Graph "
            Write-Warning "operations!"
            Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            if ($scripted) {
                throw "Failing due to missing authorization."
            }
        }
        else {
            Write-Warning "Assigned role '$appRoleName' to '$principalId'."
        }
    }
}

# Get role with given name and assign it to the principal
Function Add-Roles() {
    Param(
        [Parameter(Mandatory)][string] $principalId
    )
    Add-AppRole -appRoleName "Application.ReadWrite.All" -principalId $principalId
    Add-AppRole -appRoleName "Group.ReadWrite.All" -principalId $principalId
}

$result = @{ }
if ([string]::IsNullOrWhiteSpace($script:ResourceGroup)) {
    # create or update a service principal and get object id
    if ([string]::IsNullOrWhiteSpace($script:Name)) {
        $sp = New-AzADServicePrincipal -Role Contributor 
    }
    else {
        if (!$script:Name.StartsWith("http://") -and `
           (!$script:Name.StartsWith("https://"))) {
            $newName = "http://$($script:Name)"
            Write-Warning `
              $("Changing `"$($script:Name)`" to a valid URI of `"$newName`", " `
              + "which is the required format used for service principal names.")
            $script:Name = $newName
        }
        $app = Get-AzAdApplication -IdentifierUri $script:Name `
            -AzContext $script:Context -ErrorAction SilentlyContinue
        if (!$app) {
            $app = New-AzADApplication -DisplayName $script:Name `
                -IdentifierUris $script:Name -AzContext $script:Context
            if (!$app) {
                throw "Failed to create service principal application $($script:Name)."
            }
        }
        $sp = Get-AzADServicePrincipal -ApplicationId $app.ApplicationId `
            -AzContext $script:Context -ErrorAction SilentlyContinue
        if (!$sp) {
            $sp = New-AzADServicePrincipal -ApplicationId $app.ApplicationId `
                -Role Contributor -AzContext $script:Context 
            if (!$sp) {
                throw "Failed to create service principal $($script:Name) for rbac."
            }
        }
        $secret = $sp.Secret
        if (!$secret) {
            Write-Warning "Updating password for service principal $($script:Name)..."
            $secret = $(New-AzADSpCredential -ServicePrincipalObject $sp `
                -AzContext $script:Context).Secret
            if (!$secret) {
                throw "Failed to assign secret to service principal $($script:Name)."
            }
        }
    }
    Add-Roles -principalId $sp.Id

    $secret = [System.Net.NetworkCredential]::new("", $secret).Password
    $result.Add("aadPrincipalId", $script:Name)
    $result.Add("aadPrincipalSecret", $secret)
    $result.Add("aadTenantId", $script:Context.Tenant.Id)
}
else {
    if ([string]::IsNullOrWhiteSpace($script:Name)) {
        throw "You must supply a name for the identity to create using -Name parameter."
    }
    $rg = Get-AzResourceGroup -ResourceGroupName $script:ResourceGroup `
        -AzContext $script:Context -ErrorAction SilentlyContinue
    if (!$rg) {
        if ([string]::IsNullOrWhiteSpace($script:Location)) {
            throw "You must supply a location for the identity using -Location parameter."
        }
        $rg = New-AzResourceGroup -ResourceGroupName $script:ResourceGroup `
            -Location $script:Location `
            -AzContext $script:Context
        if (!$rg) {
            throw "Failed to create a resource group for the identity."
        }
    }
    $msi = Get-AzUserAssignedIdentity -ResourceGroupName $rg.ResourceGroupName `
        -Name $script:Name `
        -AzContext $script:Context -ErrorAction SilentlyContinue
    if (!$msi) {
        $msi = New-AzUserAssignedIdentity -ResourceGroupName $rg.ResourceGroupName `
            -Location $rg.Location -Name $script:Name `
            -AzContext $script:Context
    }
    
    Add-Roles -principalId $msi.PrincipalId
    $result.Add("aadPrincipalId", $msi.Id)
    $result.Add("aadTenantId", $msi.TenantId)
}

Disconnect-MgGraph
if ($scripted) {
    return $result
}
else {
    return $result | ConvertTo-Json
}
# -------------------------------------------------------------------------------

