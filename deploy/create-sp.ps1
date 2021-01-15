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
#>

param(
    [string] $Name = $null,
    [string] $Subscription = $null,
    [string] $ResourceGroup = $null,
    [string] $Location = $null,
    [string] $EnvironmentName = "AzureCloud", 
    [object] $DefaultProfile = $null
)

# -------------------------------------------------------------------------------
& {
    Import-Module Az 
    Import-Module Microsoft.Graph 
} *>$null

$ErrorActionPreference = "Stop"
# -------------------------------------------------------------------------------

$scripted=$($null -ne $script:DefaultProfile)
if (!$scripted) {
    Connect-AzAccount -Environment $script:EnvironmentName 3>&1>$null
    if ([string]::IsNullOrWhiteSpace($script:Subscription)) {
        $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

        if ($subscriptions.Count -eq 0) {
            throw "No active subscriptions found - exiting."
        }
        elseif ($subscriptions.Count -eq 1) {
            $script:Subscription = $subscriptions[0].Id
        }
        else {
            Write-Host "Please choose a subscription from this list (using its index):"
            $script:index = 0
            $subscriptions | Format-Table -AutoSize -Property `
            @{Name = "Index"; Expression = { ($script:index++) } }, `
            @{Name = "Subscription"; Expression = { $_.Name } }, `
            @{Name = "Id"; Expression = { $_.SubscriptionId } }`
            | Out-Host
            while ($true) {
                $option = Read-Host ">"
                try {
                    if ([int]$option -ge 1 -and [int]$option -le $subscriptions.Count) {
                        break
                    }
                }
                catch {
                    Write-Warning "Invalid index '$($option)' provided."
                }
                Write-Host `
            "Choose from the list using an index between 1 and $($subscriptions.Count)."
            }
            $script:Subscription = $subscriptions[$option - 1].Id
        }
    }
    $script:DefaultProfile = (Get-AzSubscription -SubscriptionId $script:Subscription `
        | Set-AzContext)
}

# get access token if profile provided
$accessToken = Get-AzAccessToken -TenantId $script:DefaultProfile.Tenant.Id `
    -DefaultProfile $script:DefaultProfile `
    -ResourceUrl "https://graph.microsoft.com"
if (!$accessToken) {
    throw "Failed to get access token for Microsoft Graph."
}

Connect-MgGraph -AccessToken $accessToken.Token -TenantId $accessToken.TenantId 1>$null

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
    for ($a = 1; !$(Get-MgServicePrincipal -ServicePrincipalId $principalId 2>$null); $a++) {
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
            -DefaultProfile $script:DefaultProfile -ErrorAction SilentlyContinue
        if (!$app) {
            $app = New-AzADApplication -DisplayName $script:Name `
                -IdentifierUris $script:Name -DefaultProfile $script:DefaultProfile
            if (!$app) {
                throw "Failed to create service principal application $($script:Name)."
            }
        }
        $sp = Get-AzADServicePrincipal -ApplicationId $app.ApplicationId `
            -DefaultProfile $script:DefaultProfile -ErrorAction SilentlyContinue
        if (!$sp) {
            $sp = New-AzADServicePrincipal -ApplicationId $app.ApplicationId `
                -Role Contributor -DefaultProfile $script:DefaultProfile 
            if (!$sp) {
                throw "Failed to create service principal $($script:Name) for rbac."
            }
        }
        $secret = $sp.Secret
        if (!$secret) {
            Write-Warning "Updating password for service principal $($script:Name)..."
            $secret = $(New-AzADSpCredential -ServicePrincipalObject $sp `
                -DefaultProfile $script:DefaultProfile).Secret
            if (!$secret) {
                throw "Failed to assign secret to service principal $($script:Name)."
            }
        }
    }
    Add-AppRole -appRoleName "Application.ReadWrite.All" -principalId $sp.Id

    $secret = [System.Net.NetworkCredential]::new("", $secret).Password
    $result.Add("aadPrincipalId", $script:Name)
    $result.Add("aadPrincipalSecret", $secret)
    $result.Add("aadTenantId", $script:DefaultProfile.Tenant.Id)
}
else {
    if ([string]::IsNullOrWhiteSpace($script:Name)) {
        throw "You must supply a name for the identity to create using -Name parameter."
    }
    $rg = Get-AzResourceGroup -ResourceGroupName $script:ResourceGroup `
        -DefaultProfile $script:DefaultProfile -ErrorAction SilentlyContinue
    if (!$rg) {
        if ([string]::IsNullOrWhiteSpace($script:Location)) {
            throw "You must supply a location for the identity using -Location parameter."
        }
        $rg = New-AzResourceGroup -ResourceGroupName $script:ResourceGroup `
            -Location $script:Location `
            -DefaultProfile $script:DefaultProfile
        if (!$rg) {
            throw "Failed to create a resource group for the identity."
        }
    }
    $msi = Get-AzUserAssignedIdentity -ResourceGroupName $rg.ResourceGroupName `
        -Name $script:Name `
        -DefaultProfile $script:DefaultProfile -ErrorAction SilentlyContinue
    if (!$msi) {
        $msi = New-AzUserAssignedIdentity -ResourceGroupName $rg.ResourceGroupName `
            -Location $rg.Location -Name $script:Name `
            -DefaultProfile $script:DefaultProfile
    }
    Add-AppRole -appRoleName "Application.ReadWrite.All" -principalId $msi.PrincipalId
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

