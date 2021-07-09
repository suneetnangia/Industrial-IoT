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
    Project objects are provided)
 .PARAMETER Projects
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
 .PARAMETER NoNamespace
    Do not publish using a namespace
 .PARAMETER Fast
    Perform a fast build.  This will only build what is needed for 
    the system to run in its default deployment setup.
 .PARAMETER ThrottleLimit
    Max concurrent threads to run publishing work on.
#>

Param(
    [string] $Path = $null,
    [array] $Projects = $null,
    [string] $Registry = $null,
    [string] $Subscription = $null,
    [object] $RegistryInfo = $null,
    [switch] $Debug,
    [switch] $NoNamespace,
    [switch] $Fast,
    [int] $ThrottleLimit = 16
)

# -------------------------------------------------------------------------
# Build all projects if no project objects provided
if ((!$script:Projects) -or ($script:Projects.Count -eq 0)) {
    [array]$script:Projects = & (Join-Path $PSScriptRoot "build-all.ps1") `
        -Path $script:Path `
        -Debug:$script:Debug -Fast:$script:Fast -Clean
    if ((!$script:Projects) -or ($script:Projects.Count -eq 0)) {
        Write-Warning "Nothing to build under $($script:Path)."
        return
    }
}
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
# Publish the build output to the registry
$startTime = $(Get-Date)
$argumentList = @("pull", "ghcr.io/oras-project/oras:v0.12.0")
& docker $argumentList 2>&1 | Out-Null
$s = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$rspool = [runspacefactory]::CreateRunspacePool(1, $script:ThrottleLimit, $s, $host)
$rspool.Open()
$jobs = @()
Write-Host "Publishing $($script:Projects.Count) projects as artifacts..."
foreach ($project in $script:Projects) {
    if (!$script:Project.Runtimes -or ($script:Project.Runtimes.Count -eq 0)) {
        Write-Warning "No runtimes to publish for $($project.Name)."
        continue
    }
    $PowerShell = [powershell]::Create()
    $PowerShell.RunspacePool = $rspool
    [void]$PowerShell.AddScript({
        return & (Join-Path $args[0] "publish-one.ps1") `
            -RegistryInfo $args[1] -Project $args[2] `
            -Debug:$args[3] -Fast:$args[3] -NoNamespace:$args[4]
    }, $true)
    [void]$PowerShell.AddArgument($PSScriptRoot)
    [void]$PowerShell.AddArgument($script:RegistryInfo)
    [void]$PowerShell.AddArgument($project)
    [void]$PowerShell.AddArgument($script:Debug.IsPresent)
    [void]$PowerShell.AddArgument($script:Fast.IsPresent)
    [void]$PowerShell.AddArgument($script:NoNamespace.IsPresent)
    $jobs += @{
        PowerShell = $PowerShell
        Name = $project.Name
        Handle = $PowerShell.BeginInvoke()
    }
}
# -------------------------------------------------------------------------
$projects = @()
$complete = $false
while (!$complete) {
    Start-Sleep -Seconds 3
    $complete = $true
    foreach ($job in $jobs) {
        if (!$job.Handle) {
            continue
        }
        if ($job.Handle.IsCompleted) {
            $project = $job.PowerShell.EndInvoke($job.Handle)
            $job.PowerShell.Dispose()
            $job.Handle = $null
            if (!$project) {
                Write-Warning "Publishing artifact for $($job.Name) skipped."
            }
            else {
                Write-Verbose "Publishing artifact for $($job.Name) completed."
                $projects += $project
            }
        }
        else {
            $complete = $false
        }
    }
}
$rspool.Close()
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "took $($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Publishing $($script:Projects.Count) projects $($elapsedString)..." 
# -------------------------------------------------------------------------
return $projects