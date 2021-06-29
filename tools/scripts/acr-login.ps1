<#
 .SYNOPSIS
    Gets information about azure container registry and optionally
    logs in to use docker.

 .DESCRIPTION
    The script requires az to be installed and already logged in.
    This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER Registry
    The name of the registry
 .PARAMETER Subscription
    The subscription to use - otherwise uses default

 .PARAMETER ResourceGroupName
    The name of the resource group to create if registry does not
    exist (Optional).
 .PARAMETER ResourceGroupLocation
    The location of the resource group to create (Optional).

 .PARAMETER Login
    Perform a docker login to allow other tools pick up credentials
    through the docker confg instead of using username/password.
 .PARAMETER NoNamespace
    Do not find namespace and set default registries for discovered
    branch if no registry name is provided.
#>

Param(
    [string] $Registry = $null,
    [string] $Subscription = $null,
    [string] $ResourceGroupName = $null,
    [string] $ResourceGroupLocation = $null,
    [switch] $NoNamespace,
    [switch] $Login
)

# -------------------------------------------------------------------------
$startTime = $(Get-Date)
# Collect namespace information
$namespace = ""
if (!$script:NoNamespace.IsPresent) {
    $branchName = $env:BUILD_SOURCEBRANCH
    if (![string]::IsNullOrEmpty($branchName)) {
        # Building as part of ci/cd pipeline. Try get branch name
        if ($branchName.StartsWith("refs/heads/")) {
            $branchName = $branchName.Replace("refs/heads/", "")
        }
        else {
            Write-Warning "'$($branchName)' is not a branch."
            $branchName = $null
        }
    }

    if ([string]::IsNullOrEmpty($branchName)) {
        # try getting the namespace from git
        try {
            $argumentList = @("rev-parse", "--abbrev-ref", "HEAD")
            $branchName = (& "git" $argumentList 2>&1 | `
                ForEach-Object { "$_" });
            if ($LastExitCode -ne 0) {
                throw "git $($argumentList) failed with $($LastExitCode)."
            }
        }
        catch {
            Write-Warning $_.Exception
            $branchName = $null
        }
    }

    if ([string]::IsNullOrEmpty($branchName) -or `
        ($branchName -eq "HEAD")) {
        $namespace = "branchless"
    }
    else {
        # Set namespace name based on branch name
        $namespace = $branchName
        if ($namespace.StartsWith("feature/")) {
            # dev feature builds
            $namespace = $namespace.Replace("feature/", "")
        }
        elseif ($namespace.StartsWith("release/") -or `
               ($namespace -eq "main")) {
            $namespace = "public"
            if ([string]::IsNullOrEmpty($script:Registry)) {
                # Release and Preview builds go into staging
                $script:Registry = "industrialiot"
                $script:Subscription = "IOT_GERMANY"
                $script:ResourceGroupName = $null
                Write-Warning "Using $($script:Registry).azurecr.io."
            }
        }
        $namespace = $namespace.Replace("_", "/")
        $namespace = $namespace.Substring(0, `
            [Math]::Min($namespace.Length, 24))
    }

    # set default registry
    if ([string]::IsNullOrEmpty($script:Registry)) {
        $script:Registry = $env.BUILD_REGISTRY
        if ([string]::IsNullOrEmpty($script:Registry)) {
            # Feature builds by default build into dev registry
            $script:Registry = "industrialiotdev"
            $script:Subscription = "IOT_GERMANY"
            $script:ResourceGroupName = $null
            Write-Warning "Using $($script:Registry).azurecr.io."
        }
    }
}

# ------------------------------------------------------------------
# set subscription if not provided
if ([string]::IsNullOrEmpty($script:Subscription)) {
    $argumentList = @("account", "show")
    $account = & az $argumentList 2>$null | ConvertFrom-Json
    if (!$account) {
        throw "Failed to retrieve account information."
    }
    $script:Subscription = $account.name
    Write-Host "Using default subscription $script:Subscription..."
}

# ------------------------------------------------------------------
# get registry information
$registryInfo = $null
if (![string]::IsNullOrEmpty($script:Registry)) {
    $argumentList = @("acr", "show", "--name", $script:Registry, 
        "--subscription", $script:Subscription)
    $result = (& az $argumentList 2>&1 | ForEach-Object { "$_" })
    if ($LastExitCode -eq 0) {
        $registryInfo = $result | ConvertFrom-Json
    }
}
if ((!$registryInfo) -and `
    (![string]::IsNullOrEmpty($script:ResourceGroupName))) {
    # check if group exists and if not create it.
    $argumentList = @("group", "show", "-g", $script:ResourceGroupName,
        "--subscription", $script:Subscription)
    $group = & az $argumentList 2>$null | ConvertFrom-Json
    if (!$group) {
        if ([string]::IsNullOrEmpty($script:ResourceGroupLocation)) {
            throw "Need a location to create the resource group."
        }
        $argumentList = @("group", "create", "-g", $script:ResourceGroupName, `
            "-l", $script:ResourceGroupLocation, 
            "--subscription", $script:Subscription)
        $group = & az $argumentList | ConvertFrom-Json
        if ($LastExitCode -ne 0) {
            throw "az $($argumentList) failed with $($LastExitCode)."
        }
        Write-Host "Created new Resource group $ResourceGroupName."
    }
    if ([string]::IsNullOrEmpty($script:ResourceGroupLocation)) {
        $script:ResourceGroupLocation = $group.location
    }
    # check if acr exist and if not create it
    $argumentList = @("acr", "list", "-g", $script:ResourceGroupName,
        "--subscription", $script:Subscription)
    $registries = & az $argumentList 2>$null | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($script:Registry)) {
        if ($registries) {
            # Select first registry
            $registryInfo = $registries[0]
        }
        else {
            $script:Registry = "acr$script:ResourceGroupName"
        }  
    }
    if (!$registryInfo) {
        $argumentList = @("acr", "create", 
            "-g", $script:ResourceGroupName, "-n", $script:Registry,
            "-l", $script:ResourceGroupLocation,
            "--sku", "Basic", "--admin-enabled", "true", 
            "--subscription", $script:Subscription)
        $registryInfo = & az $argumentList | ConvertFrom-Json
        if ($LastExitCode -ne 0) {
            throw "az $($argumentList) failed with $($LastExitCode)."
        }
        Write-Host "Created new Container registry in $ResourceGroupName."
    }
    else {
        Write-Host "Using Container registry $($registryInfo.name)."
    }
}
if (!$registryInfo) {
    throw "Could not find registry info.  Check if registry exists."
}

# get credentials
$argumentList = @("acr", "credential", "show", "--name", 
    $registryInfo.name, "--subscription", $script:Subscription)
$credentials = (& az $argumentList 2>&1 `
    | ForEach-Object { "$_" }) | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}
# log into the registry if requested
if ($script:Login.IsPresent) {
    $argumentList = @("acr", "login", "--name", $registryInfo.name, 
        "--subscription", $script:Subscription)
    & az $argumentList 2>&1 | Out-Null
    if ($LastExitCode -ne 0) {
        throw "az $($argumentList) failed with $($LastExitCode)."
    }
}
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Login to $($registryInfo.name) took $($elapsedString)..." 
# -------------------------------------------------------------------------
# return result
return @{
    Registry = $registryInfo.name
    Subscription = $script:Subscription
    ResourceGroup = $registryInfo.resourceGroup
    Namespace = $namespace
    LoginServer = $registryInfo.loginServer
    User = $credentials.username
    Password = $credentials.passwords[0].value
}
