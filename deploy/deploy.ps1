<#
 .SYNOPSIS
    Deploys Industrial IoT services to Azure.

 .DESCRIPTION
    Deploys the Industrial IoT services dependencies, and optionally microservices and UI to Azure.

 .PARAMETER type
    The type of deployment (minimum, local, services, simulation, app, all), defaults to all.

 .PARAMETER version
    Set to "latest" or another mcr image tag to deploy - if not set deploys current master branch ("preview").

 .PARAMETER dockerServer
    An optional name of an Azure container registry to deploy containers from.

 .PARAMETER tenantId
    An optional tenant id that should be used to access the subscriptions.

 .PARAMETER aadPreConfiguration
    The aad configuration object (use aad-register.ps1 to create object). If not provided, calls aad-register.ps1.

 .PARAMETER environmentName
    The cloud environment to use, defaults to AzureCloud.

 .PARAMETER simulationProfile
    If you are deploying a simulation, the simulation profile to use, if not default.

 .PARAMETER numberOfSimulationsPerEdge
    Number of simulations to deploy per edge.

 .PARAMETER numberOfLinuxGateways
    Number of Linux gateways to deploy into the simulation.

 .PARAMETER numberOfWindowsGateways
    Number of Windows gateways to deploy into the simulation.
#>

param(
    [ValidateSet("minimum", "local", "services", "simulation", "app", "all")] [string] $type = "all",
    [string] $version,
    [string] $dockerServer,
    [string] $tenamtId,
    [string] $simulationProfile,
    [int] $numberOfLinuxGateways = 0,
    [int] $numberOfWindowsGateways = 0,
    [int] $numberOfSimulationsPerEdge = 0,
    $aadPreConfiguration,
    [string] $environmentName = "AzureCloud"
)

# -------------------------------------------------------------------------------
& {
    Import-Module Az 
    Import-Module Az.ManagedServiceIdentity 
} *>$null

$ErrorActionPreference = "Stop"
$script:ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
$script:requiredProviders = @(
    "microsoft.devices",
    "microsoft.documentdb",
    "microsoft.servicebus",
    "microsoft.eventhub",
    "microsoft.storage",
    "microsoft.keyvault",
    "microsoft.compute",
    "microsoft.managedidentity",
    "Microsoft.containerservice",
    "microsoft.containerregistry"
)
# -------------------------------------------------------------------------------

# find the top most folder with solution in it
Function Get-RootFolder() {
    param(
        $startDir
    )
    $cur = $startDir
    while (![string]::IsNullOrEmpty($cur)) {
        if (Test-Path -Path (Join-Path $cur "Industrial-IoT.sln") -PathType Leaf) {
            return $cur
        }
        $cur = Split-Path $cur
    }
    return $startDir
}

# Login and select subscription to deploy into
Function Select-Context() {
    [OutputType([Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext])]
    Param(
        $environment,
        [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext] $script:context
    )

    Write-Host "Signing in ..."
    Write-Host
    
    $rootDir = Get-RootFolder $script:ScriptDir
    $script:contextFile = Join-Path $rootDir ".user"
    if (!$script:context) {
        # Migrate .user file into root (next to .env)
        if (!(Test-Path $script:contextFile)) {
            $oldFile = Join-Path $script:ScriptDir ".user"
            if (Test-Path $oldFile) {
                Move-Item -Path $oldFile -Destination $script:contextFile
            }
        }
        if (Test-Path $script:contextFile) {
            $imported = Import-AzContext -Path $script:contextFile
            if (($null -ne $imported) `
                    -and ($null -ne $imported.Context) `
                    -and ($null -ne (Get-AzSubscription))) {
                $script:context = $imported.Context
            }
        }
    }
    if (!$script:context) {
        try {
            $connection = Connect-AzAccount -Environment $environment.Name `
                -ErrorAction Stop
            $script:context = $connection.Context
        }
        catch {
            throw "The login to the Azure account was not successful."
        }
    }

    $tenantIdArg = @{}
    if (![string]::IsNullOrEmpty($script:tenantId)) {
        $tenantIdArg = @{
            TenantId = $script:tenantId
        }
    }

    $subscriptionDetails = $null
    if (![string]::IsNullOrEmpty($script:subscriptionName)) {
        $subscriptionDetails = Get-AzSubscription -SubscriptionName $script:subscriptionName @tenantIdArg
    }

    if (!$subscriptionDetails -and ![string]::IsNullOrEmpty($script:subscriptionId)) {
        $subscriptionDetails = Get-AzSubscription -SubscriptionId $script:subscriptionId @tenantIdArg
    }

    if (!$subscriptionDetails) {
        $subscriptions = Get-AzSubscription @tenantIdArg | Where-Object { $_.State -eq "Enabled" }

        if ($subscriptions.Count -eq 0) {
            throw "No active subscriptions found - exiting."
        }
        elseif ($subscriptions.Count -eq 1) {
            $subscriptionId = $subscriptions[0].Id
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
                    Write-Host "Invalid index '$($option)' provided."
                }
                Write-Host "Choose from the list using an index between 1 and $($subscriptions.Count)."
            }
            $subscriptionId = $subscriptions[$option - 1].Id
        }
        $subscriptionDetails = Get-AzSubscription -SubscriptionId $subscriptionId @tenantIdArg
        if (!$subscriptionDetails) {
            throw "Failed to get details for subscription $($subscriptionId)"
        }
    }

    # Update context
    $writeProfile = $false
    if ($script:context.Subscription.Id -ne $subscriptionDetails.Id) {
        $script:context = ($subscriptionDetails | Set-AzContext)
        # If file exists - silently update profile
        $writeProfile = Test-Path $script:contextFile
    }
    # If file does not exist yet - ask
    if (!(Test-Path $script:contextFile)) {
        $reply = Read-Host -Prompt "To avoid logging in again next time, would you like to save your credentials? [y/n]"
        if ($reply -match "[yY]") {
            Write-Host "Your Azure login context will be saved into a .user file in the root of the local repo."
            Write-Host "Make sure you do not share it and delete it when no longer needed."
            $writeProfile = $true
        }
    }
    if ($writeProfile) {
        Save-AzContext -Path $script:contextFile
    }

    Write-Host "Azure subscription $($script:context.Subscription.Name) ($($script:context.Subscription.Id)) selected."
    return $script:context
}


# Filter locations for provider and resource type
Function Select-ResourceGroupLocations() {
    param (
        $locations,
        $provider,
        $typeName
    )
    $regions = @()
    foreach ($item in $(Get-AzResourceProvider -ProviderNamespace $provider)) {
        foreach ($resourceType in $item.ResourceTypes) {
            if ($resourceType.ResourceTypeName -eq $typeName) {
                foreach ($region in $resourceType.Locations) {
                    $regions += $region
                }
            }
        }
    }
    if ($regions.Count -gt 0) {
        $locations = $locations | Where-Object {
            return $_.DisplayName -in $regions
        }
    }
    return $locations
}

# Select location
Function Select-ResourceGroupLocation() {
    # Filter resource namespaces
    $locations = Get-AzLocation | Where-Object {
        foreach ($provider in $script:requiredProviders) {
            if ($_.Providers -notcontains $provider) {
                return $false
            }
        }
        return $true
    }

    # Filter resource types - TODO read parameters from table
    $locations = Select-ResourceGroupLocations -locations $locations `
        -provider "Microsoft.Devices" -typeName "ProvisioningServices"

    Write-Host "Please choose a location for your deployment from this list (using its Index):"
    $script:index = 0
    $locations | Format-Table -AutoSize -property `
    @{Name = "Index"; Expression = { ($script:index++) } }, `
    @{Name = "Location"; Expression = { $_.DisplayName } } `
    | Out-Host
    while ($true) {
        $option = Read-Host -Prompt ">"
        try {
            if ([int]$option -ge 1 -and [int]$option -le $locations.Count) {
                break
            }
        }
        catch {
            Write-Host "Invalid index '$($option)' provided."
        }
        Write-Host "Choose from the list using an index between 1 and $($locations.Count)."
    }
    $script:resourceGroupLocation = $locations[$option - 1].Location
}

# Update resource group tags
Function Set-ResourceGroupTags() {
    Param(
        [string] $state,
        [string] $version
    )
    $resourceGroup = Get-AzResourceGroup -ResourceGroupName $script:resourceGroupName
    if (!$resourceGroup) {
        return
    }
    $tags = $resourceGroup.Tags
    if (!$tags) {
        $tags = @{}
    }
    $update = $false
    if (![string]::IsNullOrEmpty($state)) {
        if ($tags.ContainsKey("IoTSuiteState")) {
            if ($tags.IoTSuiteState -ne $state) {
                $tags.IoTSuiteState = $state
                $update = $true
            }
        }
        else {
            $tags += @{ "IoTSuiteState" = $state }
            $update = $true
        }
    }
    if (![string]::IsNullOrEmpty($version)) {
        if ($tags.ContainsKey("IoTSuiteVersion")) {
            if ($tags.IoTSuiteVersion -ne $version) {
                $tags.IoTSuiteVersion = $version
                $update = $true
            }
        }
        else {
            $tags += @{ "IoTSuiteVersion" = $version }
            $update = $true
        }
    }
    $type = "AzureIndustrialIoT"
    if ($tags.ContainsKey("IoTSuiteType")) {
        if ($tags.IoTSuiteType -ne $type) {
            $tags.IoTSuiteType = $type
            $update = $true
        }
    }
    else {
        $tags += @{ "IoTSuiteType" = $type }
        $update = $true
    }
    if (!$update) {
        return
    }
    $resourceGroup = Set-AzResourceGroup -Name $script:resourceGroupName -Tag $tags
}

# Get or create new resource group for deployment
Function Select-ResourceGroup() {

    $first = $true
    while ([string]::IsNullOrEmpty($script:resourceGroupName) `
            -or ($script:resourceGroupName -notmatch "^[a-z0-9-_]*$")) {
        if ($first -eq $false) {
            Write-Host "Use alphanumeric characters as well as '-' or '_'."
        }
        else {
            Write-Host
            Write-Host "Please provide a name for the resource group."
            $first = $false
        }
        $script:resourceGroupName = Read-Host -Prompt ">"
    }

    $resourceGroup = Get-AzResourceGroup -Name $script:resourceGroupName `
        -ErrorAction SilentlyContinue
    if (!$resourceGroup) {
        Write-Host "Resource group '$script:resourceGroupName' does not exist."
        Select-ResourceGroupLocation
        $resourceGroup = New-AzResourceGroup -Name $script:resourceGroupName `
            -Location $script:resourceGroupLocation
        Write-Host "Created new resource group $($script:resourceGroupName) in $($resourceGroup.Location)."
        Set-ResourceGroupTags -state "Created"
        return $True
    }
    else {
        Set-ResourceGroupTags -state "Updating"
        $script:resourceGroupLocation = $resourceGroup.Location
        Write-Host "Using existing resource group $($script:resourceGroupName)..."
        return $False
    }
}

# Get env file content from deployment
Function Get-EnvironmentVariables() {
    Param(
        $deployment
    )
    $var = $script:resourceGroupName
    if (![string]::IsNullOrEmpty($script:resourceGroupName)) {
        Write-Output "PCS_RESOURCE_GROUP=$($script:resourceGroupName)"
    }
    $var = $deployment.Outputs["keyVaultUri"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_KEYVAULT_URL=$($var)"
    }
    $var = $deployment.Outputs["clientAppId"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_AUTH_PUBLIC_CLIENT_APPID=$($var)"
    }
    $var = $deployment.Outputs["tenantId"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_AUTH_TENANT=$($var)"
    }
    $var = $deployment.Outputs["serviceUrl"].Value
    if (![string]::IsNullOrEmpty($var)) {
        Write-Output "PCS_SERVICE_URL=$($var)"
    }
}

# -------------------------------------------------------------------------------

$templateParameters = @{ }

# Select branch component - default to master
if ([string]::IsNullOrEmpty($script:branchName)) {
    # Try get branch name
    $script:branchName = $env:BUILD_SOURCEBRANCH
    if (![string]::IsNullOrEmpty($script:branchName)) {
        if ($script:branchName.StartsWith("refs/heads/")) {
            $script:branchName = $script:branchName.Replace("refs/heads/", "")
        }
        else {
            # try git
            $script:branchName = $null
        }
    }
}
# Try to use git to get a branch name and repo to deploy from 
if ([string]::IsNullOrEmpty($script:branchName)) {
    try {
        $argumentList = @("rev-parse", "--abbrev-ref", "@{upstream}")
        $symbolic = (& "git" $argumentList 2>&1 | ForEach-Object { "$_" });
        if ($LastExitCode -ne 0) {
            throw "git $($argumentList) failed with $($LastExitCode)."
        }
        $remote = $symbolic.Split('/')[0]
        $argumentList = @("remote", "get-url", $remote)
        $script:branchName = $symbolic.Replace("$($remote)/", "")
        if ($script:branchName -eq "HEAD") {
            Write-Warning "$($symbolic) is not a branch - using master."
            $script:branchName = "master"
        }
    }
    catch {
        # use the repo url -as is-
        $script:branchName = $null
    }
}
if (![string]::IsNullOrEmpty($script:branchName) -and
    ([string]::IsNullOrEmpty($script:repo))) {
    # deploy from a branch on github
    $script:repo = "https://raw.githubusercontent.com/Azure/Industrial-IoT"
}

# Select version of the docker images to deploy 
if ([string]::IsNullOrEmpty($script:version)) {
    if (![string]::IsNullOrEmpty($script:branchName) -and 
        ($script:branchName.StartsWith("release/"))) {
        $script:version = $script:branchName.Replace("release/", "")
        # default docker server is mcr so no need to set it here
    }
    else {
        $script:version = "preview"
        if ([string]::IsNullOrEmpty($script:dockerServer)) {
            $script:dockerServer = "industrialiotdev.azurecr.io"
        }
    }
}

Write-Host "Using '$($script:version)' version..."

# Select application name
if (($script:type -eq "local") -or ($script:type -eq "simulation")) {
    if ([string]::IsNullOrEmpty($script:applicationName) `
            -or ($script:applicationName -notmatch "^[a-z0-9-]*$")) {
        $script:applicationName = $script:resourceGroupName.Replace('_', '-')
    }
    if ($script:type -eq "local") {
        $templateParameters.Add("deployOptionalServices", $true)
    }
}
else {
    if ($script:type -eq "all") {
        $templateParameters.Add("deployOptionalServices", $true)
    }

    $first = $true
    while ([string]::IsNullOrEmpty($script:applicationName) `
            -or ($script:applicationName -notmatch "^[a-z0-9-]*$")) {
        if ($first -eq $false) {
            Write-Host "You can only use alphanumeric characters as well as '-'."
        }
        else {
            Write-Host
            Write-Host "Please specify a name for your application."
            $first = $false
        }
        if ($script:resourceGroupName -match "^[a-z0-9-]*$") {
            Write-Host "Hit enter to use $($script:resourceGroupName)."
        }
        $script:applicationName = Read-Host -Prompt ">"
        if ([string]::IsNullOrEmpty($script:applicationName)) {
            $script:applicationName = $script:resourceGroupName
        }
    }
}

Write-Host "...  Using '$($script:applicationName)' as name for the deploymenbt."
$templateParameters.Add("applicationName", $script:applicationName)

# Select source of the scripts and templates consumed during deployment
$templateUrl = $null
if (![string]::IsNullOrEmpty($script:branchName)) {
    Write-Host "...  Deployment using '$($script:branchName)' branch in '$($script:repo)'."
    $script:repo = "$($script:repo)/$($script:branchName)"
}
else {
    # deploy from storage account
    Write-Host "...  Deployment using '$($script:repo)' url as source."
}
$templateUrl = "$($script:repo)/deploy/templates/";
$templateParameters.Add("scriptsUrl", "$($script:repo)/deploy/scripts/")
$templateParameters.Add("templateUrl", $templateUrl)

# Select containers to deploy and where from.
if ($script:type -ne "local") {
    if (![string]::IsNullOrEmpty($script:version)) {
        $templateParameters.Add("imagesTag", $script:version)
    }
    if (![string]::IsNullOrEmpty($script:dockerServer)) {
        $templateParameters.Add("dockerServer", $script:dockerServer)
    }
    Write-Host "... Deploying $($script:version) tagged containers from $($script:dockerServer)."
}
else {
    Write-Host "... Local development - no containers will be deployed."
}
if (($script:type -eq "local") -or ($script:type -ne "simulation")) {
    $templateParameters.Add("deployPlatformComponents", $false)
}
else {
    $templateParameters.Add("deployPlatformComponents", $true)
    Write-Host "... Deploying platform using Helm chart."
}

### Todo - select resource group name before creating...

# Log in
$script:context = Select-Context -context $script:context `
    -environment (Get-AzEnvironment -Name $script:environmentName)

# Create resource group
$script:deleteOnErrorPrompt = Select-ResourceGroup
# Update tags to show deploying
Set-ResourceGroupTags -state "Deploying" -version $script:branchName

# Configure simulation
if ($script:type -eq "simulation") {
    if ([string]::IsNullOrEmpty($script:simulationProfile)) {
        $script:simulationProfile = "default"
    }
    if ((-not $script:numberOfLinuxGateways) -or ($script:numberOfLinuxGateways -eq 0)) {
        $script:numberOfLinuxGateways = 1
    }
    if ((-not $script:numberOfWindowsGateways) -or ($script:numberOfWindowsGateways -eq 0)) {
        $script:numberOfWindowsGateways = 1
    }
    if ((-not $script:numberOfSimulationsPerEdge) -or ($script:numberOfSimulationsPerEdge -eq 0)) {
        $script:numberOfSimulationsPerEdge = 1
    }

    $templateParameters.Add("simulationProfile", $script:simulationProfile)
    $templateParameters.Add("numberOfLinuxGateways", $script:numberOfLinuxGateways)
    $templateParameters.Add("numberOfWindowsGateways", $script:numberOfWindowsGateways)
    $templateParameters.Add("numberOfSimulations", $script:numberOfSimulationsPerEdge)

    # Get all vm skus available in the location and in the account
    $availableVms = Get-AzComputeResourceSku | Where-Object {
        ($_.ResourceType.Contains("virtualMachines")) -and `
        ($_.Locations -icontains $script:resourceGroupLocation) -and `
        ($_.Restrictions.Count -eq 0)
    }
    # Sort based on sizes and filter minimum requirements
    $availableVmNames = $availableVms  | Select-Object -ExpandProperty Name -Unique
    # We will use VM with at least 2 cores and 8 GB of memory as gateway host.
    $edgeVmSizes = Get-AzVMSize $script:resourceGroupLocation `
    | Where-Object { $availableVmNames -icontains $_.Name } `
    | Where-Object {
        ($_.NumberOfCores -ge 2) -and `
        ($_.MemoryInMB -ge 8192) -and `
        ($_.OSDiskSizeInMB -ge 1047552) -and `
        ($_.ResourceDiskSizeInMB -gt 8192)
    } `
    | Sort-Object -Property `
        NumberOfCores, MemoryInMB, ResourceDiskSizeInMB, Name
    # Pick top
    if ($edgeVmSizes.Count -ne 0) {
        $edgeVmSize = $edgeVmSizes[0].Name
        Write-Host "... Using $($edgeVmSize) as VM size for all edge simulation gateway hosts..."
        $templateParameters.Add("edgeVmSize", $edgeVmSize)
    }

    # We will use VM with at least 1 core and 2 GB of memory for hosting PLC simulation containers.
    $simulationVmSizes = Get-AzVMSize $script:resourceGroupLocation `
    | Where-Object { $availableVmNames -icontains $_.Name } `
    | Where-Object {
        ($_.NumberOfCores -ge 1) -and `
        ($_.MemoryInMB -ge 2048) -and `
        ($_.OSDiskSizeInMB -ge 1047552) -and `
        ($_.ResourceDiskSizeInMB -ge 4096)
    } `
    | Sort-Object -Property `
        NumberOfCores, MemoryInMB, ResourceDiskSizeInMB, Name
    # Pick top
    if ($simulationVmSizes.Count -ne 0) {
        $simulationVmSize = $simulationVmSizes[0].Name
        Write-Host "... Using $($simulationVmSize) as VM size for all edge simulation hosts..."
        $templateParameters.Add("simulationVmSize", $simulationVmSize)
    }
}

# Configure aad registration
if (!$script:aadPreConfiguration) {
    $msi = & (Join-Path $script:ScriptDir "create-sp.ps1") -DefaultProfile $script:context `
        -Name "deploy_aad_msi" -ResourceGroup $script:resourceGroupName  `
        -Location $script:resourceGroupLocation -Subscription $script:subscriptionId
    if ([string]::IsNullOrWhiteSpace($msi.aadPrincipalId)) {
        throw "Failed to create managed service identity for application registration."
    }
    $templateParameters.Add("aadPrincipalId", $msi.aadPrincipalId)
}
elseif (($script:aadPreConfiguration -is [string]) -and (Test-Path $script:aadPreConfiguration)) {
    # read configuration from file
    $script:aadPreConfiguration = Get-Content -Raw -Path $script:aadPreConfiguration | ConvertFrom-Json
    $templateParameters.Add("aadPreConfiguration", $script:aadPreConfiguration)
}

# Add IoTSuiteType tag. This tag will be applied for all resources.
$tags = @{"IoTSuiteType" = "AzureIndustrialIoT-$($script:version)-PS1" }
$templateParameters.Add("tags", $tags)

if (!$script:dumpTemplateParameterJson) {
    return $templateParameters | ConvertTo-Json
}
else {
    Write-Host "The following template parameters will be used:"
    Write-Host $templateParameters | ConvertTo-Json
}

# Do the deployment
$script:requiredProviders | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ } | Out-Null
while ($true) {
    try {
        Write-Host "Starting deployment..."

        $StartTime = $(Get-Date)
        Write-Host "... Start time: $($StartTime.ToShortTimeString())"

        # Start the deployment from template Url
        $deployment = New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
            -TemplateUri $(Join-Path $templateUrl "azuredeploy.json") `
            -RollbackToLastDeployment -DeploymentDebugLogLevel All `
            -SkipTemplateParameterPrompt -TemplateParameterObject $templateParameters
        if ($deployment.ProvisioningState -ne "Succeeded") {
            Set-ResourceGroupTags -state "Failed"
            throw "Deployment $($deployment.ProvisioningState)."
        }

        Set-ResourceGroupTags -state "Complete"
  
        $elapsedTime = $(Get-Date) - $StartTime
        Write-Host "... Elapsed time (hh:mm:ss): $($elapsedTime.ToString("hh\:mm\:ss"))" 

        Write-Host "Deployment succeeded."

        # Create environment file
        $rootDir = Get-RootFolder $script:ScriptDir
        $writeFile = $false
        $ENVVARS = Join-Path $rootDir ".env"
        $prompt = "Save environment as $ENVVARS for local development? [y/n]"
        $reply = Read-Host -Prompt $prompt
        if ($reply -match "[yY]") {
            $writeFile = $true
        }
        if ($writeFile) {
            if (Test-Path $ENVVARS) {
                $prompt = "Overwrite existing .env file in $rootDir? [y/n]"
                if ($reply -match "[yY]") {
                    Remove-Item $ENVVARS -Force
                }
                else {
                    $writeFile = $false
                }
            }
        }

        if ($writeFile) {
            Get-EnvironmentVariables $deployment | Out-File -Encoding ascii `
                -FilePath $ENVVARS

            Write-Host
            Write-Host ".env file created in $rootDir."
            Write-Host
            Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Warning "!The file contains security keys to your Azure resources!"
            Write-Warning "! Safeguard the contents of this file, or delete it now !"
            Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Host
        }
        else {
            Get-EnvironmentVariables $deployment | Out-Default
        }        Write-EnvironmentVariables -deployment $deployment
        return
    }
    catch {
        $ex = $_
        Write-Host $_.Exception.Message
        Write-Host "Deployment failed."

        $deleteResourceGroup = $false
        $retry = Read-Host -Prompt "Try again? [y/n]"
        if ($retry -match "[yY]") {
            continue
        }
        if ($script:deleteOnErrorPrompt) {
            $reply = Read-Host -Prompt "Delete resource group? [y/n]"
            $deleteResourceGroup = ($reply -match "[yY]")
        }
        if ($deleteResourceGroup) {
            try {
                Write-Host "Removing resource group $($script:resourceGroupName)..."
                Remove-AzResourceGroup -ResourceGroupName $script:resourceGroupName -Force
            }
            catch {
                Write-Warning $_.Exception.Message
            }
        }
        throw $ex
    }
}
