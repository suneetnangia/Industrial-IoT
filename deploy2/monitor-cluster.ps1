<#
 .SYNOPSIS
  Shows the cluster dashboard.

 .DESCRIPTION
  If needed deploys the dashboard to the cluster and opens a browser
  to the proxied dashboard page.  The script requires AzureCLI (AZ)
  and Kubectl to be installed.

 .PARAMETER ResourceGroup
  The Name of the resource group

 .PARAMETER Cluster
  The optional cluster name if there are more than one in the group.
   
 .PARAMETER Subscription
  The subscription to set if not already set.
#>
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,
    [string] $Subscription = $null,
    [string] $Cluster = $null
)

# -------------------------------------------------------------------------
$script:ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------
# Log into azure
$argumentList = @("account", "show")
& "az" $argumentList 2>&1 | ForEach-Object { Write-Host "$_" } | Out-Null
if ($LastExitCode -ne 0) {
    $argumentList = @("login")
    & "az" $argumentList 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LastExitCode -ne 0) {
        throw "az $($argumentList) failed with $($LastExitCode)."
    }
}

# -------------------------------------------------------------------------
# set default subscription
if (![string]::IsNullOrEmpty($script:Subscription)) {
    Write-Debug "Setting subscription to $($script:Subscription)"
    $argumentList = @("account", "set", "--subscription", $script:Subscription)
    & "az" $argumentList 2>&1 | Out-Null
    if ($LastExitCode -ne 0) {
        throw "az $($argumentList) failed with $($LastExitCode)."
    }
}

if ([string]::IsNullOrEmpty($script:Cluster)) {
    $argumentList = @("aks", "list", "-g", $script:ResourceGroup, `
        "--query", "[0].name", "-o", "tsv")
    $script:Cluster=$(& "az" $argumentList)
    if (($LastExitCode -ne 0) -or ([string]::IsNullOrEmpty($script:Cluster))) {
Write-Warning "ERROR: Unable to determine aks cluster name."
Write-Warning "ERROR: Ensure one was created in resource group $script:ResourceGroup."
        throw "ERROR: Unable to determine cluster name."
    }
}

$argumentList = @("version", "--client")
& "kubectl" $argumentList 2>&1 | Out-Null
if ($LastExitCode -ne 0) {
    Write-Warning "Installing kubectl..."
    $argumentList = @("aks", "install-cli")
    & "az" $argumentList 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LastExitCode -ne 0) {
        throw "ERROR: Failed to install kubectl."
    }
}

# Get AKS admin credentials
$argumentList = @("aks", "get-credentials", "-g", $script:ResourceGroup, `
    "--name", $script:Cluster, "--admin")
& "az" $argumentList 2>&1 | ForEach-Object { Write-Host "$_" }
if ($LastExitCode -ne 0) {
    throw "ERROR: Failed to get credentials for cluster."
}
        
# install dashboard into the cluster
$tag="v2.1.0" # v2.0.0, master, etc.
$url="https://raw.githubusercontent.com/kubernetes/dashboard/$tag/aio/deploy/recommended.yaml"
$argumentList = @("apply", "--force", "-f", $url)
& "kubectl" $argumentList 
if ($LastExitCode -ne 0) {
    throw "ERROR: Failed to install dashboard."
}

# start proxy and open browser
$job = Start-Job { while ($true) { try { & "kubectl" @("proxy") } catch { } } }
Start-Sleep -Seconds 5
$url="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
Start-Process -FilePath $url
Receive-Job -Job $Job -Wait -AutoRemoveJob
# -------------------------------------------------------------------------
