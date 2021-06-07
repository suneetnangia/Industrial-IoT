<#
 .SYNOPSIS
    Builds docker images from definition files in folder or the entire 
    tree into a container registry.

 .DESCRIPTION
    The script traverses the build root to find all folders with an 
    container.json file builds each one.

    If resource group or registry name is provided, creates or uses the 
    container registry in the resource group to build with. In this case
    you must use az login first to authenticate to azure.

 .PARAMETER Path
    The root folder to start traversing the source from.
 .PARAMETER Output
    The root folder for all artifacts output (Optional).

 .PARAMETER ResourceGroupName
    The name of the resource group to create (Optional).
 .PARAMETER ResourceGroupLocation
    The location of the resource group to create (Optional).
 .PARAMETER Subscription
    The subscription to use (Optional).

 .PARAMETER Debug
    Whether to build debug images.
 .PARAMETER Clean
    Perform a clean build. 

 .PARAMETER Fast
    Perform a fast build.  This will only build what is needed for 
    the system to run in its default deployment setup.
#>

Param(
    [string] $Path = $null,
    [string] $Output = $null,
    [string] $Registry = $null,
    [string] $ResourceGroupName = $null,
    [string] $ResourceGroupLocation = $null,
    [string] $Subscription = $null,
    [switch] $Debug,
    [switch] $Clean,
    [switch] $Fast
)

$startTime = $(Get-Date)
$BuildRoot = & (Join-Path $PSScriptRoot "get-root.ps1") -fileName "*.sln"
if ([string]::IsNullOrEmpty($script:Path)) {
    $script:Path = $BuildRoot
}

# Check if we should build or push into registry
if (!$script:Registry -and (![string]::IsNullOrEmpty($script:ResourceGroupName))) {

    if ([string]::IsNullOrEmpty($script:Subscription)) {
        $argumentList = @("account", "show")
        $account = & "az" $argumentList 2>$null | ConvertFrom-Json
        if (!$account) {
            throw "Failed to retrieve account information."
        }
        $script:Subscription = $account.name
        Write-Host "Using default subscription $script:Subscription..."
    }

    # check if group exists and if not create it.
    $argumentList = @("group", "show", "-g", $script:ResourceGroupName,
        "--subscription", $script:Subscription)
    $group = & "az" $argumentList 2>$null | ConvertFrom-Json
    if (!$group) {
        if ([string]::IsNullOrEmpty($script:ResourceGroupLocation)) {
            throw "Need a resource group location to create the resource group."
        }
        $argumentList = @("group", "create", "-g", $script:ResourceGroupName, `
            "-l", $script:ResourceGroupLocation, 
            "--subscription", $script:Subscription)
        $group = & "az" $argumentList | ConvertFrom-Json
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
    $registries = & "az" $argumentList 2>$null | ConvertFrom-Json
    $script:Registry = if ($registries) { $registries[0] } else { $null }
    if (!$script:Registry) {
        $argumentList = @("acr", "create", "-g", $script:ResourceGroupName, "-n", `
            "acr$script:ResourceGroupName", "-l", $script:ResourceGroupLocation, `
            "--sku", "Basic", "--admin-enabled", "true", 
            "--subscription", $script:Subscription)
        $script:Registry = & "az" $argumentList | ConvertFrom-Json
        if ($LastExitCode -ne 0) {
            throw "az $($argumentList) failed with $($LastExitCode)."
        }
        Write-Host "Created new Container registry in $ResourceGroupName."
    }
    else {
        Write-Host "Using Container registry $($script:Registry.name)."
    }
}

$containers = @{}
# If registry was specified check if there is a results file in the output folder
if ($script:Registry -and !$script:Clean.IsPresent) {
    if (![string]::IsNullOrEmpty($script:Output)) {
        $resultsFile = Join-Path $script:Output build.json
        if (Test-Path $resultsFile) {
            $containers = Get-Content -Raw -Path $resultsFile | ConvertFrom-Json
            if ($containers.Count -eq 0) {
                throw "Results file exists but is empty."
            }
        }
    }
}

# If no previous results, build first
if ($containers.Keys.Count -eq 0) {
    if (![string]::IsNullOrEmpty($script:Output)) {
        Remove-Item (Join-Path $script:Output build.json) -ErrorAction SilentlyContinue
    }

    # Traverse from build root and find all container.json metadata files and build
    Get-ChildItem $script:Path -Recurse -Include "container.json" | ForEach-Object {
        # Get root
        $metadataPath = $_.DirectoryName.Replace($BuildRoot, "")
        if (![string]::IsNullOrEmpty($metadataPath)) {
            $metadataPath = $metadataPath.Substring(1)
        }
        $metadata = Get-Content -Raw -Path (join-path $_.DirectoryName "container.json") `
            | ConvertFrom-Json
        if (!$metadata) {
            return
        }
        # See if we should build into registry directly, otherwise just build
        Write-Host "Building $($metadata.name) in $metadataPath..."
        $container = & (Join-Path $PSScriptRoot "dotnet-build.ps1") `
            -Path $metadataPath -Output $script:Output `
            -Debug:$script:Debug -Fast:$script:Fast -Clean:$script:Clean
        if ($container) {
            $containers.Add($metadata.name, $container)
        }
    }

    # Save any results if output folder provided as specified and exit
    if (!$script:Registry) {
        if ((![string]::IsNullOrEmpty($script:Output)) -and ($containers.Keys.Count -gt 0)) {
            $containers | ConvertTo-Json | Out-File (Join-Path $script:Output build.json)
        }
    }
}

# Build artifacts and images
if ($script:Registry -and ($containers.Keys.Count -gt 0)) {
    $containers.Keys | ForEach-Object {
        $container = $containers.Item($_)

        # Push runtime artifacts to registry
        Write-Host "Pushing $($container.name) ..."
        & (Join-Path $PSScriptRoot "acr-build.ps1") -Container $container `
            -Registry $script:Registry.name -Subscription $script:Subscription `
            -Debug:$script:Debug -Fast:$script:Fast
    }
}

$elapsedTime = $(Get-Date) - $startTime
Write-Host "Build took $($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)" 
return $containers