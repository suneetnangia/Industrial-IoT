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

# -------------------------------------------------------------------------
$startTime = $(Get-Date)
$BuildRoot = & (Join-Path $PSScriptRoot "get-root.ps1") -fileName "*.sln"
if ([string]::IsNullOrEmpty($script:Path)) {
    $script:Path = $BuildRoot
}

# -------------------------------------------------------------------------
# Log into registry - create if it does not exist
if ((![string]::IsNullOrEmpty($script:Registry)) -or `
    (![string]::IsNullOrEmpty($script:ResourceGroupName))) {
    $registryInfo = & (Join-Path $PSScriptRoot "acr-login.ps1") `
        -Registry $script:Registry -Subscription $script:Subscription `
        -ResourceGroupName $script:ResourceGroupName `
        -ResourceGroupLocation $script:ResourceGroupLocation `
        -NoNamespace
    if (!$registryInfo) {
        throw "Failed to log into $script:Registry"
    }
    $script:Registry = $registryInfo.Registry
    $script:Subscription = $registryInfo.Subscription
}

# -------------------------------------------------------------------------
$projects = @()
# If registry was specified see if there is a results file in the output 
# folder to continue from
if ((![string]::IsNullOrEmpty($script:Registry)) -and `
    (!$script:Clean.IsPresent)) {
    if (![string]::IsNullOrEmpty($script:Output)) {
        $resultsFile = Join-Path $script:Output "projects.json"
        if (Test-Path $resultsFile) {
            $projects = Get-Content -Raw -Path $resultsFile `
                | ConvertFrom-Json
            if ($projects.Count -eq 0) {
                throw "Results file exists but is empty."
            }
        }
    }
}

# -------------------------------------------------------------------------
# If no previous results, build first
if ($projects.Count -eq 0) {
    if (![string]::IsNullOrEmpty($script:Output)) {
        Remove-Item $(Join-Path $script:Output "projects.json") `
            -ErrorAction SilentlyContinue
    }

    # Traverse from build root and find all container.json metadata files
    Get-ChildItem $script:Path -Recurse -Include "container.json" `
        | ForEach-Object {
        # Get root
        $metadataPath = $_.DirectoryName.Replace($BuildRoot, "")
        if (![string]::IsNullOrEmpty($metadataPath)) {
            $metadataPath = $metadataPath.Substring(1)
        }
        $metadata = Get-Content -Raw `
            -Path (join-path $_.DirectoryName "container.json") `
                | ConvertFrom-Json
        if (!$metadata) {
            return
        }
        # See if we should build into registry directly, otherwise just build
        $project = & (Join-Path $PSScriptRoot "dotnet-build.ps1") `
            -Path $metadataPath -Output $script:Output `
            -Debug:$script:Debug -Fast:$script:Fast -Clean:$script:Clean
        if ($project) {
            $projects += $project
        }
    }

    # Save projects to output folder provided as specified and exit
    if ((![string]::IsNullOrEmpty($script:Output)) -and `
        ($projects.Count -gt 0)) {
        $projects `
            | ConvertTo-Json -Depth 4 `
            | Out-File $(Join-Path $script:Output "projects.json")
    }
}

# -------------------------------------------------------------------------
# Build artifacts and images
if ((![string]::IsNullOrEmpty($script:Registry)) -and `
        ($projects.Count -gt 0)) {
    Write-Host "Building registry artifacts and containers..."
    & (Join-Path $PSScriptRoot "acr-tasks.ps1") -Projects $projects `
        -Registry $script:Registry -Subscription $script:Subscription `
        -Debug:$script:Debug -Fast:$script:Fast
}

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
Write-Host "Build took $($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)" 
return $projects