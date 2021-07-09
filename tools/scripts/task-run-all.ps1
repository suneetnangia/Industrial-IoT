<#
 .SYNOPSIS
    Sets up tasks and runs these tasks using a task artifact as input.
 .DESCRIPTION
    The script requires az to be installed and already logged on to a 
    subscription.  This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER TaskArtifact
    The task artifact OCI container image to use to boot strap all 
    tasks in the same registry. 
 .PARAMETER Subscription
    The subscription to use - otherwise uses default
    
 .PARAMETER IsLatest
    Release as latest image
 .PARAMETER IsMajorUpdate
    Release as major update
 .PARAMETER NoNamespace
    Remove namespace (e.g. public) on release.
 .PARAMETER ThrottleLimit
    Max concurrent threads to run tasks.
#>

Param(
    [Parameter(Mandatory = $true)] [string] $TaskArtifact,
    [string] $Subscription = $null,
    [switch] $IsLatest,
    [switch] $IsMajorUpdate,
    [switch] $NoNamespace,
    [int] $ThrottleLimit = 32
)

# -------------------------------------------------------------------------
# Get registry from artifact
$registry = $TaskArtifact.Split('/')[0]
if (!$registry -like "*.azurecr.io") {
    throw "Artifact $script:TaskArtifact is not an ACR artifact."
    # here we could import it first if we wanted to.
}

# get namespace and tag from artifact to use for releases 
$namespace = $TaskArtifact.Replace("$($registry)/", "")
$artifactTag = $namespace.Split(':')[1]
# add the output / release image tags
if ($script:NoNamespace.IsPresent) {
    $namespace = ""
}
else {
    $namespace = $namespace.Split(':')[0]
    $namespace = $namespace.Replace($namespace.Split('/')[-1], "")
    $namespace = $namespace.Trim('/')
    Write-Host "Creating tasks with namespace $namespace ..."
}

# -------------------------------------------------------------------------
# Get registry information
$registry = $registry.Replace(".azurecr.io", "")
$registryInfo = & (Join-Path $PSScriptRoot "acr-login.ps1") -Login `
    -Registry $registry -Subscription $script:Subscription -NoNamespace
if (!$registryInfo) {
    throw "Failed to get registry information for $script:Registry"
}

# -------------------------------------------------------------------------
# Create tasks from task artifact
$startTime = $(Get-Date)
Write-Host "Creating and running tasks from $($script:TaskArtifact)..."
$argumentList = @("manifest", "inspect", $script:TaskArtifact)
$manifest = (& docker $argumentList 2>&1 | ForEach-Object { "$_" }) `
    | ConvertFrom-Json

# Get layers with annotations and based on those create all the tasks
$tasks = @()
$manifest.layers | ForEach-Object {
    $annotations = $_.annotations
    $taskname = $annotations."com.microsoft.azure.acr.task.name"
    if ([string]::IsNullOrEmpty($taskname)) {
        # expected for non build tasks
        return
    }
    $version = $annotations."com.microsoft.azure.acr.task.version"
    if ([string]::IsNullOrEmpty($version)) {
        $version = $artifactTag
    }
    $platform = $annotations."com.microsoft.azure.acr.task.platform"
    if ([string]::IsNullOrEmpty($platform)) {
        $platform = "linux"
    }
    $taskfile = $annotations."org.opencontainers.image.title"
    
    # For all versions create tasks
    $targetTags = @()
    if ($script:IsLatest.IsPresent) {
        $targetTags += "latest"
    }

    # Example: if version is 2.8.1, then image tags are "2", "2.8", "2.8.1"
    $versionParts = $version.Split('.')
    if ($versionParts.Count -gt 0) {
        $versionTag = $versionParts[0]
        if ($script:IsMajorUpdate.IsPresent -or $script:IsLatest.IsPresent) {
            $targetTags += $versionTag
        }
        for ($i = 1; $i -lt ($versionParts.Count); $i++) {
            $versionTag = ("$($versionTag).{0}" -f $versionParts[$i])
            $targetTags += $versionTag
        }
    }
    
    $taskname = $taskname.Substring(0, [Math]::Min($taskname.Length, 45))
    Write-Verbose "Creating or updating $($taskname) tasks for releases 
$($targetTags -join ", ") on $($platform) from $($script:TaskArtifact)
and using $($taskfile)..."
    foreach ($targetTag in $targetTags) {
        $fullName = "$($taskname)-$($targetTag.Replace('.', '-'))"
        
        # Create tasks in the registry from the task context artifact
        Write-Verbose "Creating task $($fullName) ..."
        # Create acr command line 
        $argumentList = @("acr", "task", "create", 
            "--name", $fullName,
            "--registry", $registryInfo.Registry,
            "--resource-group", $registryInfo.ResourceGroup,
            "--subscription", $registryInfo.Subscription,
            "--file", $taskfile,
            "--platform", $platform,
            "--set", "Tag=$($targetTag)",
            "--set", "Namespace=$($namespace)",
            "--base-image-trigger-type", "All",
            "--commit-trigger-enabled", "False", 
            "--pull-request-trigger-enabled", "False",
            "--context", "oci://$($script:TaskArtifact)"
        )
        $createLogs = & az $argumentList 2>&1 | ForEach-Object { "$_" } 
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList -join " ")
            Write-Warning "az $cmd failed with $LastExitCode - 2nd attempt..."
            $createLogs | ForEach-Object { Write-Warning "$_" }
            $createLogs = & az $argumentList 2>&1 | ForEach-Object { "$_" } 
            if ($LastExitCode -ne 0) {
                $createLogs | ForEach-Object { Write-Warning "$_" }
                throw "Error: 'az $cmd' 2nd attempt failed with $LastExitCode."
            }
        }
        Write-Host "Task $($fullName) created or updated successfully."
        $createLogs | Write-Verbose
        $tasks += $fullName
    }
}
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "took $($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Creating tasks from $($script:TaskArtifact) $($elapsedString)..." 

# -------------------------------------------------------------------------
# Run all tasks and wait for completion
function RunAllTasks {
    Param(
        [array] $TaskNames,
        [switch] $NoBuild,
        [switch] $NoManifest
    )
$s = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$rspool = [runspacefactory]::CreateRunspacePool(1, $script:ThrottleLimit, $s, $host)
    $rspool.Open()
    $jobs = @()
    foreach ($taskName in $TaskNames) {
        $PowerShell = [powershell]::Create()
        $PowerShell.RunspacePool = $rspool
        [void]$PowerShell.AddScript({
            & (Join-Path $args[0] "task-run-one.ps1") `
                -RegistryInfo $args[1] -TaskName $args[2] `
                -NoManifest:$args[3] -NoBuild:$args[4]
        }, $True)
        [void]$PowerShell.AddArgument($PSScriptRoot)
        [void]$PowerShell.AddArgument($registryInfo)
        [void]$PowerShell.AddArgument($taskName)
        [void]$PowerShell.AddArgument($NoManifest.IsPresent)
        [void]$PowerShell.AddArgument($NoBuild.IsPresent)
        $jobs += @{
            PowerShell = $PowerShell
            Name = $taskName
            Handle = $PowerShell.BeginInvoke()
        }
    }
    $complete = $false
    while (!$complete) {
        Start-Sleep -Seconds 3
        $complete = $true
        foreach ($job in $jobs) {
            if (!$job.Handle) {
                continue
            }
            if ($job.Handle.IsCompleted) {
                $job.PowerShell.EndInvoke($job.Handle) | Out-Host
                $job.PowerShell.Dispose()
                $job.Handle = $null
                Write-Verbose "$($job.Name) completed."
            }
            else {
                $complete = $false
            }
        }
    }
    $rspool.Close()
}

# -------------------------------------------------------------------------
# first build without manifest to create the initial images
$startTime = $(Get-Date)
Write-Host "Building without manifest..."
RunAllTasks -TaskNames $tasks -NoManifest
Write-Host "Creating manifests..."
RunAllTasks -TaskNames $tasks -NoBuild
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Running all tasks took $($elapsedString)..." 
# -------------------------------------------------------------------------
