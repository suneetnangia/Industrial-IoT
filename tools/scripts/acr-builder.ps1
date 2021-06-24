<#
 .SYNOPSIS
    Sets up tasks from a task artifact.

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
    [string] $TaskArtifact,
    [string] $Subscription = $null,
    [switch] $IsLatest,
    [switch] $IsMajorUpdate,
    [switch] $RemoveNamespaceOnRelease
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

$taskname = $taskname.Substring(0, [Math]::Min($taskname.Length, 45))

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
    
    Write-Verbose "Creating $($taskname) tasks for releases 
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
        Write-Host "Task $($fullName) created successfully."
        $createLogs | Write-Verbose
        $tasks += $fullName
    }
}

$jobs = @()
foreach ($taskName in $tasks) {
    # run the task
    $argumentList = @(
        "--name", $taskName,
        "--registry", $registryInfo.Registry,
        "--resource-group", $registryInfo.ResourceGroup,
        "--subscription", $registryInfo.Subscription
    )
    $jobs += Start-Job -Name $taskName `
        -ArgumentList @($argumentList, $taskName) -ScriptBlock {
        
        # measure run
        $startTime = $(Get-Date)
        $commonArgs = $args[0]
        $taskName = $args[1]
        Write-Host "Starting task run for $($taskName)..."
        for($i = 0; $i -lt 5; $i++) {
            $argumentList = @("acr", "task", "run", "--set", "NoManifest=1")
            $argumentList += $commonArgs
            $runLogs = & az $argumentList 2>&1 | ForEach-Object {
                return "$taskName ($i) : $_"
            } 
            $cmd = $($argumentList -join " ")
            $t = "Task $taskName ($i)"
            if ($LastExitCode -ne 0) {
                $runLogs | ForEach-Object { Write-Warning "$_" }
                throw "Error: $t : 'az $cmd' failed with $LastExitCode."
            }

            # check last run
            $argumentList = @("acr", "task", "list-runs", "--top", "1")
            $argumentList += $commonArgs
            $run = $null
            while (!$run) {
                $runResult = (& az $argumentList 2>&1 `
                    | ForEach-Object { "$_" }) | ConvertFrom-Json
                $run = $runResult.runId
                $status = $runResult.status
                $t = "$t (Run ID: $($run))"
                if ([string]::IsNullOrEmpty($run) -or `
                    ($status -ne "Succeeded")) {
                    if (($status -eq "Queued") -or `
                        ($status -eq "Running")) {
                        Write-Verbose "$t in progress..."
                        Start-Sleep -Seconds 5
                        $run = $null
                    }
                    elseif ($status -eq "Timeout") {
                        $runLogs | ForEach-Object { Write-Verbose "$_" }
                        throw "Error: $t (az $cmd) timed out."
                    }
                    else {
                        $runLogs | ForEach-Object { Write-Warning "$_" }
                        Write-Warning "$t (az $cmd) completed with '$($status)'"
                    }
                }
                elseif ($status -eq "Succeeded") { 
                    # success
                    $runLogs | ForEach-Object { Write-Verbose "$_" }
                    $elapsedTime = $(Get-Date) - $startTime
                    $elapsedString = $elapsedTime.ToString("hh\:mm\:ss")
                    Write-Host "$t took $($elapsedString) (hh:mm:ss)..." 
                    # exits job
                    return
                }
            }
            Start-Sleep -Seconds 1
            Write-Host "Attempt #$i - re-starting task $($taskName) ..."
        } 
        # end of for loop t retry.
        throw "Error: Task $($taskName) failed after $($i) times."
    }
}
if ($jobs.Count -ne 0) {
    # Wait until all jobs are completed
    Receive-Job -Job $jobs -WriteEvents -Wait | Write-Verbose
    $jobs | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        throw "Error: Running task $($_.Name) resulted in $($_.State)."
    }
}

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Running all tasks took $($elapsedString)..." 
# -------------------------------------------------------------------------
