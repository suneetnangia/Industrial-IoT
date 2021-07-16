<#
 .SYNOPSIS
    Builds csproj file and returns project object containing
    the meta data of the built project used in other scripts.

 .PARAMETER Path
    The folder containing the container.json file (Mandatory).
 .PARAMETER Output
    The root folder for all output folders. If not present, 
    path is used (Optional).

 .PARAMETER Debug
    Whether to build Release or Debug - default to Release.  
    Debug also includes debugger into images (where applicable).
 .PARAMETER Clean
    Perform a clean build. This will remove all existing output
    ahead of publishing.
 .PARAMETER Fast
    Perform a fast build.  This will only build what is needed for 
    the system to run in its default deployment setup.
 .PARAMETER LinuxOnly
    Build linux only (except for edge modules at this time)
#>

Param(
    [string] $Path = $null,
    [string] $Output = $null,
    [switch] $Debug,
    [switch] $Clean,
    [switch] $Fast,
    [switch] $LinuxOnly
)

# -------------------------------------------------------------------------
# Get meta data
if ([string]::IsNullOrEmpty($Path)) {
    throw "No root folder specified."
}
if (!(Test-Path -Path $Path -PathType Container)) {
    $Path = Join-Path (& (Join-Path $PSScriptRoot "get-root.ps1") `
        -fileName $Path) $Path
}
$Path = Resolve-Path -LiteralPath $Path

$startTime = $(Get-Date)
$configuration = "Release"
if ($script:Debug.IsPresent) {
    $configuration = "Debug"
}

$metadata = Get-Content -Raw -Path (Join-Path $Path "container.json") `
    | ConvertFrom-Json
if ($script:Fast.IsPresent -and (!$metadata.buildAlways)) {
    return $null
}

# set output publish path - publish path is unique to the path being built.
$name = $metadata.name.Replace('/', '-')
if ([string]::IsNullOrEmpty($script:Output)) {
    $publishPath = Join-Path $Path `
        (Join-Path "bin" (Join-Path "publish" $configuration))
}
else {
    $publishPath = Join-Path $script:Output (Join-Path $configuration $name)
    New-Item -ItemType Directory -Force -Path $publishPath | Out-Null
}

# Create build job definitions from dotnet project in current folder
$projFile = Get-ChildItem $Path -Filter *.csproj | Select-Object -First 1
if (!$projFile) {
    return $null
}
$projName = [System.IO.Path]::GetFileNameWithoutExtension(`
    $projFile.FullName)

$proj = [xml] (Get-Content -Path $projFile.FullName)
$assemblyName = $proj.Project.PropertyGroup `
    | Where-Object { ![string]::IsNullOrWhiteSpace($_.AssemblyName) } `
    | Select-Object { $_.AssemblyName } -Last 1
if ([string]::IsNullOrWhiteSpace($assemblyName)) {
    $assemblyName = $projFile.BaseName
}

# -------------------------------------------------------------------------
# Always build as portable.
$runtimes = @("portable")
if (!$metadata.base) {
    if ($script:Fast.IsPresent -or $script:LinuxOnly.IsPresent) {
        $runtimes += "linux-musl-x64"
        # if iot edge also build for windows.
        if ($metadata.iotedge) {
            $runtimes += "win-x64"
        }
    }
    else {
        $runtimes += "linux-arm"
        $runtimes += "linux-musl-arm"
        $runtimes += "linux-arm64"
        $runtimes += "linux-musl-arm64"
        $runtimes += "linux-x64"
        $runtimes += "linux-musl-x64"
        $runtimes += "win-x64"
    }
}
$runtimeInfos = @()
foreach ($runtimeId in $runtimes) {
    $runtimeArtifact = Join-Path $publishPath $runtimeId
    if ($script:Clean.IsPresent) {
        # Clean artifact
        Remove-Item $runtimeArtifact -Recurse `
            -ErrorAction SilentlyContinue
    }

    # Create dotnet command line 
    $argumentList = @("publish", "-c", $configuration, "--force")
    if ($runtimeId -ne "portable") {
        $argumentList += "-r"
        $argumentList += $runtimeId
        $argumentList += "/p:TargetLatestRuntimePatch=true"
   
        if (!$metadata.base) {
            $argumentList += "--self-contained"
        }
    }
    else {
        $argumentList += "--self-contained=false"
    }
    #$workspace = "$name-$runtimeId-$configuration".ToLower()
    #$argumentList += "/p:BaseIntermediateOutputPath=$($workspace)-obj/"
    #$argumentList += "/p:BaseOutputPath=$($workspace)-bin/"
    $argumentList += "-o"
    $argumentList += $runtimeArtifact
    $argumentList += $projFile.FullName

Write-Verbose "Publishing $($projName) ($($runtimeId)) to $($publishPath)..."
    $buildlog = & dotnet $argumentList 2>&1
    if ($LastExitCode -ne 0) {
        $cmd = $($argumentList -join " ")
        $buildlog | ForEach-Object { Write-Warning "$_" }
        throw "Error: 'dotnet $($cmd)' failed with $($LastExitCode)."
    }
    else {
        $buildlog | ForEach-Object { Write-Verbose "$_" }
    }
    $runtimeInfos += @{
        runtimeId = $runtimeId
        artifact = $runtimeArtifact
    }
}

$project = @{
    Name = $metadata.name
    ProjectName = $projName
    ProjectPath = $projFile.FullName
    PublishPath = $publishPath
    AssemblyName = $assemblyName
    Debug = $script:Debug.IsPresent
    Metadata = $metadata
    Runtimes = $runtimeInfos
}

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Building $($projName) took $($elapsedString)..." 
# -------------------------------------------------------------------------
return $project