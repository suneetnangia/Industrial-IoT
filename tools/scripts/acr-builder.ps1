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
 .PARAMETER RemoveNamespaceOnRelease
    Remove namespace (e.g. public) on release.
#>

Param(
    [Parameter(Mandatory = $true)] [string] $TaskArtifact,
    [string] $Subscription = "IOT-OPC-WALLS",
    [switch] $IsLatest,
    [switch] $IsMajorUpdate,
    [switch] $RemoveNamespaceOnRelease,
    [int] $MaxConcurrentJobs = 8
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
if ($script:RemoveNamespaceOnRelease.IsPresent) {
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
# Picks a task from the queue to run and when completed picks the next
function RunTask {
    if($queue.Count -eq 0) {
        return
    }
    $task = $queue.Dequeue()
    if (!$task) {
        return
    }
    # Run acr task as job
    $job = Start-Job -Name $task.Name -ArgumentList @(
        $PSScriptRoot, $registryInfo, $task.Name, $task.NoManifest
    ) -ScriptBlock {
        & (Join-Path $args[0] "acr-runner.ps1") `
            -RegistryInfo $args[1] -TaskName $args[2] `
            -NoManifest:$args[3]
    }
    # when event completes, start new and remove old job
    Register-ObjectEvent -InputObject $job `
        -EventName StateChanged -Action { 
        $job = Get-Job $eventsubscriber.SourceIdentifier
        $job | Out-Host
     #   if ($job.State -ne "Completed") {
     #       return
     #   }
        RunTask
        Unregister-Event $eventsubscriber.SourceIdentifier
        # Remove-Job $eventsubscriber.SourceIdentifier
    } | Out-Null
}

# -------------------------------------------------------------------------
# Run all tasks and wait for completion
function RunAllTasks {
    Param(
        [array] $TaskNames,
        [switch] $NoManifest
    )
    $queue = [System.Collections.Queue]::Synchronized(`
        (New-Object System.Collections.Queue))
    foreach ($taskName in $TaskNames) {
        $queue.Enqueue(@{
            Name = $taskName;
            NoManifest = $NoManifest.IsPresent
        })
    }

    # remove all jobs
    Get-Job | Remove-Job
    # Start task run jobs with max concurrency
    for( $i = 0; $i -lt $script:MaxConcurrentJobs; $i++ ) {
        RunTask 
    }

    # Wait until all jobs are completed and task queue is empty
    while ($queue.Count -ne 0) {
        $jobs = Get-Job
        Receive-Job -Job $jobs -WriteEvents -Wait | Write-Verbose
        $jobs | Where-Object { $_.State -eq "Failed" } | ForEach-Object {
            throw "Error: Running task $($_.Name) failed."
        }
    }
}

# -------------------------------------------------------------------------
# first build without manifest to create the initial images
Write-Host "Building without manifest..."
RunAllTasks -TaskNames $tasks -NoManifest
Write-Host "Running task steps with manifests..."
RunAllTasks -TaskNames $tasks
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Running all tasks took $($elapsedString)..." 
# -------------------------------------------------------------------------
