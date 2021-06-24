<#
 .SYNOPSIS
    Builds all csproj files and returns project objects containing
    the meta data of the built projects which are used in other scripts.

 .PARAMETER Path
    The folder to recursively traverse to find all container.json files
    (Mandatory).
 .PARAMETER Output
    The root folder for all output folders. (Optional)

 .PARAMETER Debug
    Whether to build Release or Debug - default to Release. 
 .PARAMETER Clean
    Perform a clean build. This will remove all existing output
    ahead of publishing.
 .PARAMETER Fast
    Perform a fast build.  This will only build what is needed for 
    the system to run in its default deployment setup.
#>

Param(
    [string] $Path = $null,
    [string] $Output = $null,
    [switch] $Debug,
    [switch] $Clean,
    [switch] $Fast
)

# -------------------------------------------------------------------------
$buildRoot = & (Join-Path $PSScriptRoot "get-root.ps1") -fileName "*.sln"
if ([string]::IsNullOrEmpty($script:Path)) {
    $script:Path = $buildRoot
}
if (!(Test-Path -Path $script:Path -PathType Container)) {
    $script:Path = Join-Path (& (Join-Path $PSScriptRoot "get-root.ps1") `
        -fileName $script:Path) $script:Path
}
$script:Path = Resolve-Path -LiteralPath $script:Path
$startTime = $(Get-Date)

# -------------------------------------------------------------------------
# Get all projects to build from folder root.
$projects = @()
Get-ChildItem $script:Path -Recurse -Include "container.json" `
    | ForEach-Object {
    
    # Get root
    $metadataPath = $_.DirectoryName.Replace($buildRoot, "")
    if (![string]::IsNullOrEmpty($metadataPath)) {
        $metadataPath = $metadataPath.Substring(1)
    }
    # See if we should build into registry directly, otherwise just build
    $project = & (Join-Path $PSScriptRoot "build-one.ps1") `
        -Path $metadataPath -Output $script:Output `
        -Debug:$script:Debug -Fast:$script:Fast -Clean:$script:Clean
    if ($project) {
        $projects += $project
    }
}

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Build took $($elapsedString)..." 
return $projects










