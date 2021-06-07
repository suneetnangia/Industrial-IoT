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
#>

Param(
    [string] $TaskArtifact,
    [string] $Subscription = $null
)

# -------------------------------------------------------------------------
# Get registry from artifact
$registry = $TaskArtifact.Split('/')[0]
if (!$registry -like "*.azurecr.io") {
    throw "Artifact $script:TaskArtifact is not an ACR artifact."
}
$registry = $registry.Replace(".azurecr.io", "")
if ([string]::IsNullOrEmpty($script:Subscription)) {
    $argumentList = @("account", "show")
    $account = & "az" $argumentList 2>$null | ConvertFrom-Json
    if (!$account) {
        throw "Failed to retrieve account information."
    }
    $script:Subscription = $account.name
    Write-Host "Using default subscription $script:Subscription..."
}
# get registry information
$argumentList = @("acr", "show", "--name", $registry, 
    "--subscription", $script:Subscription)
$registryInfo = (& "az" $argumentList 2>&1 `
    | ForEach-Object { "$_" }) | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}
$resourceGroup = $registryInfo.resourceGroup
Write-Debug "Using resource group $($resourceGroup)"
# login
$argumentList = @("acr", "login", "--name", $registry, 
    "--subscription", $script:Subscription)
& "az" $argumentList 2>&1 | ForEach-Object { "$_" }
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}

# -------------------------------------------------------------------------
# Create tasks from task artifact
Write-Host "Create tasks from $($script:TaskArtifact)..."
$argumentList = @("manifest", "inspect", $script:TaskArtifact)
$manifest = (& docker $argumentList 2>&1 | ForEach-Object { "$_" }) `
    | ConvertFrom-Json
# Get layers with annotations and based on those create all the tasks
[System.Collections.ArrayList]$taskruns = @()
$manifest.layers | ForEach-Object {
    $annotations = $_.annotations
    $taskname = $annotations."com.microsoft.azure.acr.task.name"
    if ([string]::IsNullOrEmpty($taskname)) {
        # expected for non build tasks
        return
    }
    $platform = $annotations."com.microsoft.azure.acr.task.platform"
    if ([string]::IsNullOrEmpty($platform)) {
        $platform = "linux"
    }
    $taskfile = $annotations."org.opencontainers.image.title"
    # Create tasks in the registry from the task context artifact
Write-Host "Create task $($taskname) on $($platform) from $($script:TaskArtifact)..."
    # Create acr command line 
    $argumentList = @("acr", "task", "create", 
        "--name", $taskname,
        "--registry", $registry,
        "--resource-group", $resourceGroup,
        "--subscription", $script:Subscription,
        "--file", $taskfile,
        "--platform", $platform,
        "--base-image-trigger-type", "All",
        "--commit-trigger-enabled", "False", 
        "--pull-request-trigger-enabled", "False",
        "--context", "oci://$($script:TaskArtifact)"
    )
    & az $argumentList 2>&1 | ForEach-Object { "$_" }
    if ($LastExitCode -ne 0) {
        $cmd = $($argumentList | Out-String)
        Write-Warning "az $cmd failed with $LastExitCode - 2nd attempt..."
        & az $argumentList 2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            throw "Error: 'az $cmd' 2nd attempt failed with $LastExitCode."
        }
    }
    $taskruns.Add($taskname)
}

# -------------------------------------------------------------------------
# Run acr task first time to set up the base image trigger
$taskruns | ForEach-Object {
    $taskname = $_
    $argumentList = @("acr", "task", "run", 
        "--name", $taskname,
        "--registry", $registry,
        "--resource-group", $resourceGroup,
        "--subscription", $script:Subscription
    )
    Write-Host "Starting task run $($taskname) ..."
    $jobs += Start-Job -Name $taskname -ArgumentList $argumentList -ScriptBlock {
        $argumentList = $args
        & az $argumentList 2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList | Out-String)
            throw "Error: 'az $cmd' failed with $LastExitCode."
        }
    }
}

if ($jobs.Count -ne 0) {
    # Wait until all jobs are completed
    Receive-Job -Job $jobs -WriteEvents -Wait | Out-Host
    if (!$script:Fast.IsPresent) {
        $jobs | Out-Host
    }
    $jobs | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        throw "ERROR: Running task $($_.Name) resulted in $($_.State)."
    }
}

# check that all task runs completed successfully
$taskruns | ForEach-Object {
    $taskname = $_
    # Get last run result
    $argumentList = @("acr", "task", "list-runs", "--top", "1" 
        "--name", $taskname,
        "--registry", $registry,
        "--resource-group", $resourceGroup,
        "--subscription", $script:Subscription
    )
    $runResult = (& "az" $argumentList 2>&1 `
        | ForEach-Object { "$_" }) | ConvertFrom-Json
    $run = $runResult.runId
    if ([string]::IsNullOrEmpty($run) -or ($runResult.status -ne "Succeeded")) {
        throw "Error: $($taskname) run $($run) completed '$($runResult.status)'"
    }
    Write-Host "Task $($taskname) run $($run) completed successfully."
}

Write-Host "All task runs completed successfully."

# -------------------------------------------------------------------------
