<#
 .SYNOPSIS
    Publishes (and if necessary builds) all artifacts and uploads 
    them as OCI artifacts into the OCI registry..

 .DESCRIPTION
    The script requires az to be installed and already logged on to a 
    subscription. This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER Path
    The folder to build the artifacts from (Required if no 
    Project object is provided)
 .PARAMETER Project
    The project description if already built before (Required if
    no Path is provided.)

 .PARAMETER RegistryInfo
    The registry info object returned by acr-login script -
    or alternatively provide registry name through -Registry param. 
 .PARAMETER Registry
    The name of the registry if no registry object is provided.
 .PARAMETER Subscription
    The subscription to use - otherwise use the default one configured.

 .PARAMETER Debug
    Build and publish debug artifacts instead of release (default)
 .PARAMETER Fast
    Perform a fast build.  This will only build what is needed for 
    the system to run in its default deployment setup.
#>

Param(
    [string] $Path = $null,
    [object] $Project = $null,
    [string] $Registry = $null,
    [string] $Subscription = $null,
    [object] $RegistryInfo = $null,
    [switch] $Debug,
    [switch] $Fast
)

# -------------------------------------------------------------------------
# Build and publish dotnet output if no container definition provided
if (!$script:Project) {
    if ([string]::IsNullOrEmpty($Path)) {
        throw "No docker folder specified."
    }
    if (!(Test-Path -Path $Path -PathType Container)) {
        $Path = Join-Path (& (Join-Path $PSScriptRoot "get-root.ps1") `
            -fileName $Path) $Path
    }
    $Path = Resolve-Path -LiteralPath $Path
    $script:Project = & (Join-Path $PSScriptRoot "build-one.ps1") `
        -Path $Path -Debug:$script:Debug -Fast:$script:Fast -Clean
    if (!$script:Project) {
        return $null
    }
}
if ($script:Fast.IsPresent -and (!$script:Project.Metadata.buildAlways)) {
    Write-Warning "Using fast build - Skipping $($script:Project.Name)."
    return $null
}

# -------------------------------------------------------------------------
# Get registry information
if (!$script:RegistryInfo) {
    $script:RegistryInfo = & (Join-Path $PSScriptRoot "acr-login.ps1") `
        -Registry $script:Registry -Subscription $script:Subscription `
        -NoNamespace:$script:Fast
    if (!$script:RegistryInfo) {
        throw "Failed to get registry information for $script:Registry"
    }
}

# -------------------------------------------------------------------------
$startTime = $(Get-Date)
# Set image namespace
$namespace = $script:RegistryInfo.Namespace
if (![string]::IsNullOrEmpty($namespace)) {
    $namespace = "$($namespace)/"
}
else {
    $namespace = ""
}
# set source tag and revision
$sourceTag = $env:Version_Prefix
$revision = $env:Version_Full
if ([string]::IsNullOrEmpty($sourceTag)) {
    try {
        $version = & (Join-Path $PSScriptRoot "get-version.ps1")
        $sourceTag = $version.Prefix
        $revision = $version.Full
    }
    catch {
        # build as latest if not building from ci/cd pipeline
        if (!$script:Fast.IsPresent) {
            throw "Unable to determine version - skip image build."
        }
        $sourceTag = "latest"
        $revision = ""
    }
}
# Set postfix
$tagPostfix = ""
if ($script:Project.Debug -and (!$script:Fast.IsPresent)) {
    $tagPostfix = "-debug"
}

# -------------------------------------------------------------------------
# Publish runtime artifacts to registry
$argumentList = @("pull", "ghcr.io/deislabs/oras:v0.11.1")
& docker $argumentList 2>&1 | ForEach-Object { "$_" }
$jobs = @()
foreach ($runtime in $script:Project.Runtimes) {
    $created = $(Get-Date -Format "o")
    $root = Join-Path (Split-Path -Path $runtime.artifact -Parent) "workspaces"

    $workspace = Join-Path $root "$($runtime.runtimeId)$($tagPostfix)"
    Remove-Item $workspace -Recurse -Force -ErrorAction SilentlyContinue

    # content of the artifact image
    $artifactFolder = $runtime.runtimeId
    New-Item -ItemType "directory" -Path $workspace -Name $artifactFolder `
        -Force | Out-Null
    Copy-Item -Recurse -Path (Join-Path $runtime.artifact "*") `
        -Destination (Join-Path $workspace $artifactFolder)
    
    $configFile = "manifest.config.json"
    @{
        "created" = $created
        "author" = "Microsoft"
    } | ConvertTo-Json `
      | Out-File -Encoding ascii -FilePath (Join-Path $workspace $configFile)

    $annotationFile = "manifest.annotations.json"
#https://github.com/oras-project/oras-www/blob/main/docs/documentation/annotations.md
    @{
        "$($artifactFolder)" = @{
            # https://github.com/opencontainers/image-spec/blob/master/annotations.md
            "org.opencontainers.image.url" = "https://github.com/Azure/Industrial-IoT"
            "org.opencontainers.image.licenses" = "MIT"
            "org.opencontainers.image.revision" = $revision
            "org.opencontainers.image.version" = $sourceTag
            "org.opencontainers.image.source" = $branchName
            "org.opencontainers.image.vendor" = "Microsoft"
            "org.opencontainers.image.created" = $created
        }
    } | ConvertTo-Json `
      | Out-File -Encoding ascii -FilePath (Join-Path $workspace $annotationFile)

    $artifact = "$($script:RegistryInfo.LoginServer)/$($namespace)"
    $artifact = "$($artifact)$($script:Project.Name)"
    $artifact = "$($artifact):$($sourceTag)-artifact"
    $artifact = "$($artifact)-$($runtime.runtimeId)$($tagPostfix)"

    $argumentList = @("run", "--rm", "-v", "$($workspace):/workspace", 
        "ghcr.io/deislabs/oras:v0.11.1", "push", $artifact, $artifactFolder,
        "-u", $script:RegistryInfo.User, "-p", $script:RegistryInfo.Password, "-v",
        "--manifest-annotations", $annotationFile, 
        "--manifest-config", $configFile)
    $co = "uploading artifact $artifact"
    $jobs += Start-Job -Name $artifact `
        -ArgumentList @($argumentList, $co, $script:RegistryInfo.Password) `
        -ScriptBlock {
        $argumentList = $args[0]
        $co = $args[1]
        Write-Verbose "Start $($co)..."
        $pushLog = & docker $argumentList 2>&1
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList -join " ") -replace $args[2], "***"
Write-Warning "Failed $($co). 'docker $cmd' exited with $LastExitCode - 2nd attempt..."
            & docker $argumentList 2>&1 | ForEach-Object { "$_" }
            if ($LastExitCode -ne 0) {
                $pushLog | ForEach-Object { Write-Warning "$_" }
throw "Error: Failed $($co). 'docker $cmd' 2nd attempt exited with $LastExitCode."
            }
        }
        $pushLog | ForEach-Object { Write-Verbose "$_" }
        Write-Verbose "Completed $($co)."
    }
}
if ($jobs.Count -ne 0) {
    # Wait until all jobs are completed
    Receive-Job -Job $jobs -WriteEvents -Wait | Write-Verbose
    $jobs | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        throw "Error: Pushing artifact $($_.Name) resulted in $($_.State)."
    }
}

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Publishing $($script:Project.Name) took $($elapsedString)..." 
# -------------------------------------------------------------------------
return $script:Project
