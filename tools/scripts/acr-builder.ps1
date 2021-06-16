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
Write-Host "Creating and running tasks from $($script:TaskArtifact)..."
$argumentList = @("manifest", "inspect", $script:TaskArtifact)
$manifest = (& docker $argumentList 2>&1 | ForEach-Object { "$_" }) `
    | ConvertFrom-Json
# Get layers with annotations and based on those create all the tasks
$jobs = @()
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
    Write-Host "Creating $taskname tasks on $($platform) ..."
    Write-Host "... from $($script:TaskArtifact) using $taskfile..."

    # For all versions create tasks
    $targetTags = @()
    if ($script:IsLatest.IsPresent) {
        $targetTags += "latest"
    }

    # Example: if version is 2.8.1, then base image tags are "2", "2.8", "2.8.1"
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
    
    Write-Host "... for releases $($targetTags -join ", "):"
    foreach ($targetTag in $targetTags) {
        $fullName = "$($taskname)-$($targetTag.Replace('.', '-'))"
        # Create tasks in the registry from the task context artifact
        Write-Host "Creating task $($fullName) ..."
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
        & az $argumentList 2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList -join " ")
            Write-Warning "az $cmd failed with $LastExitCode - 2nd attempt..."
            & az $argumentList 2>&1 | ForEach-Object { "$_" }
            if ($LastExitCode -ne 0) {
                throw "Error: 'az $cmd' 2nd attempt failed with $LastExitCode."
            }
        }
        # run the task
        $argumentList = @(
            "--name", $fullName,
            "--registry", $registryInfo.Registry,
            "--resource-group", $registryInfo.ResourceGroup,
            "--subscription", $registryInfo.Subscription
        )
        $jobs += Start-Job -Name $fullName `
            -ArgumentList @($argumentList, $fullName) -ScriptBlock {
            
            $commonArgs = $args[0]
            $fullName = $args[1]

            Write-Verbose "Run task $($fullName) ..."
            $argumentList = @("acr", "task", "run")
            $argumentList += $commonArgs
            $runLogs = & az $argumentList 2>&1 | ForEach-Object { "$_" }
            if ($LastExitCode -ne 0) {
                $runLogs | ForEach-Object { Write-Host "$_" }
                $cmd = $($argumentList -join " ")
            throw "Error: 'Task $($fullName): az $cmd' failed with $LastExitCode."
            }

            # check last run
            $argumentList = @("acr", "task", "list-runs", "--top", "1")
            $argumentList += $commonArgs
            $runResult = (& "az" $argumentList 2>&1 `
                | ForEach-Object { "$_" }) | ConvertFrom-Json
            $run = $runResult.runId
            if ([string]::IsNullOrEmpty($run) -or ($runResult.status -ne "Succeeded")) {
                $runLogs | ForEach-Object { Write-Host "$_" }
            throw "Error: Task $($fullName) run $($run) completed '$($runResult.status)'"
            }
            else {
                $runLogs | ForEach-Object { Write-Verbose "$_" }
            }
            Write-Host "Task $($fullName) Run $($run) completed successfully."
        }
    }
}

if ($jobs.Count -ne 0) {
    # Wait until all jobs are completed
    Receive-Job -Job $jobs -WriteEvents -Wait | Write-Verbose
    $jobs | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        throw "Error: Running task $($_.Name) resulted in $($_.State)."
    }
}

Write-Host "All task runs completed successfully."
Write-Host ""
# -------------------------------------------------------------------------
