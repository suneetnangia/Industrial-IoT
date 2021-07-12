<#
 .SYNOPSIS
    Publishes (and if necessary builds) helm as artifact.

 .DESCRIPTION
    The script requires helm and az to be installed and already logged 
    on to a subscription. This means it should be run in a azcliv2 task
    in the azure pipeline or "az login" must have been performed already.

 .PARAMETER ChartPath
    Path to the chart (optional)
 .PARAMETER ChartName
    Name under which to publish the chart (optional)

 .PARAMETER RegistryInfo
    The registry info object returned by acr-login script -
    or alternatively provide registry name through -Registry param. 
 .PARAMETER Registry
    The name of the registry if no registry object is provided.
 .PARAMETER Subscription
    The subscription to use - otherwise use the default one configured.

 .PARAMETER NoNamespace
    No namespace (e.g. public) should be used.
 .PARAMETER IsLatest
    Chart as latest image
#>

Param(
    [string] $ChartPath = $null,
    [string] $ChartName = "azure-industrial-iot",
    [string] $Registry = $null,
    [string] $Subscription = $null,
    [object] $RegistryInfo = $null,
    [switch] $NoNamespace,
    [switch] $IsLatest
)

# -------------------------------------------------------------------------
# Get registry information
if (!$script:RegistryInfo) {
    $script:RegistryInfo = & (Join-Path $PSScriptRoot "acr-login.ps1") `
        -Registry $script:Registry -Subscription $script:Subscription `
        -NoNamespace:$script:NoNamespace
    if (!$script:RegistryInfo) {
        throw "Failed to get registry information for $script:Registry"
    }
}

# -------------------------------------------------------------------------
$startTime = $(Get-Date)
$buildRoot = & (Join-Path $PSScriptRoot "get-root.ps1") -fileName "*.sln"
if ([string]::IsNullOrEmpty($script:ChartPath)) {
    $script:ChartPath = Join-Path `
    (Join-Path (Join-Path $buildRoot "deploy2") "helm") $script:ChartName
}
# Set image namespace
$namespace = $script:RegistryInfo.Namespace
if (![string]::IsNullOrEmpty($namespace) -and `
    (!$script:NoNamespace.IsPresent)) {
    $namespace = "$($namespace)/"
}
else {
    $namespace = ""
}
# set source tag and revision
$targetTags = @()
$sourceTag = $env:Version_Prefix
if ([string]::IsNullOrEmpty($sourceTag)) {
    try {
        $version = & (Join-Path $PSScriptRoot "get-version.ps1")
        $sourceTag = $version.Prefix
    }
    catch {
        $sourceTag = $null
    }
}
if (![string]::IsNullOrEmpty($sourceTag)) {
    $targetTags += $sourceTag
}
if ($script:IsLatest.IsPresent) {
    $targetTags += "latest"
}
# -------------------------------------------------------------------------
$helmVersion = & helm @("version", "--short")
if (($LastExitCode -ne 0) -or ($helmVersion -notlike "v3.*")) {
   Write-Host "Installing helm..."
   & az @("acr", "helm", "install", "--client-version", "3.3.4", "-y") 2>&1
}
# -------------------------------------------------------------------------
# Publish helm chart to registry
$chartBase = "$($script:RegistryInfo.LoginServer)/$namespace"
$chartBase = "$($chartBase)iot/$($script:ChartName)"
$env:HELM_EXPERIMENTAL_OCI = 1
foreach ($targetTag in $targetTags) {
    $chart = "$($chartBase):$($targetTag)"
    $argumentList = @("chart", "save", $script:ChartPath, $chart)
    $helmLog = & helm $argumentList 2>&1
    if ($LastExitCode -ne 0) {
        $helmLog | ForEach-Object { Write-Warning "$_" }
        $cmd = $($argumentList -join " ")
        throw "Error: Failed to save Helm chart $chart as image ($cmd)."
    }
    $argumentList = @("registry", "login",
        $script:RegistryInfo.LoginServer,
        "-u", $script:RegistryInfo.User, 
        "--password-stdin")
    $helmLog = $script:RegistryInfo.Password | & helm `
        $argumentList 2>&1
    if ($LastExitCode -ne 0) {
        $helmLog | ForEach-Object { Write-Warning "$_" }
        $cmd = $($argumentList -join " ")
        throw "Error: Failed to log into the registry using Helm ($cmd)."
    }
    $helmLog = & helm @("chart", "push", $chart) 2>&1
    if ($LastExitCode -ne 0) {
        $helmLog | ForEach-Object { Write-Warning "$_" }
        throw "Error: Failed to upload Helm chart $chart ($cmd)."
    }
    Write-Verbose "Helm chart $chart uploaded successfully."
}
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Publishing Helm chart took $($elapsedString)..." 
# -------------------------------------------------------------------------

