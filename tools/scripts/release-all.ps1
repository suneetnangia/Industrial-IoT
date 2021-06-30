<#
 .SYNOPSIS
    Imports artifacts and tasks into a release registry e.g. prod. 

 .DESCRIPTION
    The script requires az to be installed and already logged on to a 
    subscription.  This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER BuildRegistry
    The name of the source registry where development artifacts are 
    present.
 .PARAMETER BuildSubscription
    The subscription where the build registry is located
 .PARAMETER BuildNamespace
    Namespace to filter on in the source registry.
 
 .PARAMETER ReleaseRegistry
    The name of the destination registry where release artifacts and
    tasks will be created.
 .PARAMETER ReleaseSubscription
    The subscription of the release registry is different than build
    registry subscription
 .PARAMETER ReleaseNamespace
    Namespace to use in release registry (e.g. public)
 .PARAMETER ResourceGroupName
    The name of the resource group to create if release registry does not
    exist (Optional).
 .PARAMETER ResourceGroupLocation
    The location of the resource group to create (Optional).

 .PARAMETER ReleaseVersion
    The build version for the development artifacts that are being
    released.

 .PARAMETER IsLatest
    Release as latest image
 .PARAMETER IsMajorUpdate
    Release as major update
 .PARAMETER ReadOnly
    Will not create or write anything.
#>

Param(
    [Parameter(Mandatory = $true)] [string] $ReleaseVersion,
    [string] $BuildRegistry = "industrialiot",
    [string] $BuildSubscription = "IOT_GERMANY",
    [string] $BuildNamespace = $null,
    [string] $ReleaseRegistry = "industrialiotprod",
    [string] $ReleaseSubscription = "IOT_GERMANY",
    [string] $ReleaseNamespace = $null,
    [string] $ResourceGroupName = $null,
    [string] $ResourceGroupLocation = $null,
    [switch] $IsLatest,
    [switch] $IsMajorUpdate,
    [switch] $ReadOnly
)

# -------------------------------------------------------------------------
# Get source and target registry information
$sourceRegistry = & (Join-Path $PSScriptRoot "acr-login.ps1") `
    -Registry $script:BuildRegistry -NoNamespace `
    -Subscription $script:BuildSubscription -Login
if (!$sourceRegistry) {
    throw "Failed to get registry information for $script:BuildRegistry"
}
if (!$script:ReadOnly.IsPresent) {
    $targetRegistry = & (Join-Path $PSScriptRoot "acr-login.ps1") `
        -NoNamespace -Registry $script:ReleaseRegistry `
        -Subscription $script:ReleaseSubscription `
        -ResourceGroupName $script:ResourceGroupName `
        -ResourceGroupLocation $script:ResourceGroupLocation
    if (!$targetRegistry) {
        throw "Failed to get information for $script:ReleaseRegistry"
    }
}

# -------------------------------------------------------------------------
# Copy artifacts from build registry repositories.
$argumentList = @("acr", "repository", "list", "-ojson", 
    "--name", $sourceRegistry.Registry, 
    "--subscription", $sourceRegistry.Subscription)
$result = (& az $argumentList 2>&1 | ForEach-Object { "$_" })
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}
$buildRepos = $result | ConvertFrom-Json
Write-Host "Found $($buildRepos.Count) repos in $($sourceRegistry.Registry):"
$buildRepos | Out-Host

if (![string]::IsNullOrEmpty($script:BuildNamespace)) {
    $script:BuildNamespace = "$($script:BuildNamespace.TrimEnd('/'))/"
}

# Copy artifacts from the build repo
$images = @()
foreach ($buildRepo in $buildRepos) {
    if (![string]::IsNullOrEmpty($script:BuildNamespace)) {
        if (!$buildRepo.StartsWith($script:BuildNamespace)) {
            continue
        }
    }
    # Get tags
    $argumentList = @("acr", "repository", "show-tags", 
        "--name", $sourceRegistry.Registry,
        "--subscription", $sourceRegistry.Subscription,
        "--repository", $buildRepo,
        "-ojson"
    )
    $buildTags = (& az $argumentList 2>&1 | ForEach-Object { "$_" }) `
        | ConvertFrom-Json
    if ($LastExitCode -ne 0) {
        throw "Error: Failed to get tags in repo $buildRepo."
    }
    Write-Host "Found $($buildTags.Count) tags in $($buildRepo):"
    $buildTags | Out-Host
    foreach ($buildTag in $buildTags) {
        # Tag must be starting with the release version specified
        if (!$buildTag.StartsWith("$($script:ReleaseVersion)")) {
            continue
        }

        # Use docker manifest to see if this is an artifact and if it is...
        $buildImage = "$($buildRepo):$($buildTag)"
        $sourceImage = "$($sourceRegistry.LoginServer)/$($buildImage)"
        $argumentList = @("manifest", "inspect", $sourceImage)
        Write-Host "Inspecting manifest of $sourceImage..."
        $manifest = (& docker $argumentList 2>&1 | ForEach-Object { "$_" }) `
            | ConvertFrom-Json
        $isArtifact = $manifest.layers | Where-Object { 
            ![string]::IsNullOrEmpty(`
                $_.annotations."org.opencontainers.image.title")
        } | Select-Object -First 1
        # ... check if it is a task artifact (has task name annotations)...
        $isTaskArtifact = $manifest.layers | Where-Object { 
            ![string]::IsNullOrEmpty(`
                $_.annotations."com.microsoft.azure.acr.task.name")
        } | Select-Object -First 1

        $targetImage = $null
        if (!$script:ReadOnly.IsPresent) {
            $targetImage = "$($targetRegistry.LoginServer)/$($buildImage)"
        }
        $images += @{
            Name = $buildImage
            Target = $targetImage
            Source = $sourceImage
            IsArtifact = $isArtifact
            IsTaskArtifact = $isTaskArtifact
        }
    }
}

$jobs = @()
$taskArtifacts = @()
foreach ($image in $images) {
    $targetImage = $image.Target
    $sourceImage = $image.Source
    if (!$targetImage) {
        if (!$script:ReadOnly.IsPresent) {
            throw "Unexpected - target image is empty."
        }
        $targetImage = "target registry"
    }
    else {
        if (![string]::IsNullOrEmpty($script:BuildNamespace)) {
            $targetImage = $targetImage -replace $script:BuildNamespace, ""
        }
        if (![string]::IsNullOrEmpty($script:ReleaseNamespace)) {
            $targetImage = "$($script:ReleaseNamespace)/$($targetImage)"
        }
    }
    $co = "copying $($sourceImage) to $($targetImage) "
    if ($image.IsTaskArtifact) {
        $co += "(task artifact)."
        $taskArtifacts += $targetImage
    }
    elseif ($image.IsArtifact) {
        $co += "(build artifact)."
    }
    else {
        $co += "(image)."
    }
    if ($script:ReadOnly.IsPresent) {
        "Would be $($co)" | Out-Host
        continue
    }
    # Create acr command line to import. --force is needed to replace 
    # existing artifacts with new ones
    $argumentList = @("acr", "import", "-ojson", "--force",
        "--name", $targetRegistry.Registry,
        "--subscription", $targetRegistry.Subscription,
        "--image", $targetImage,
        "--source", $sourceImage, 
        "--username", $sourceRegistry.User,
        "--password", $sourceRegistry.Password
    )
    
    $jobs += Start-Job -Name $sourceImage `
        -ArgumentList @($argumentList, $co, $sourceRegistry.Password) `
        -ScriptBlock {
        $argumentList = $args[0]
        $co = $args[1]
        Write-Host "Start $($co)"
        & az $argumentList 2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList -join " ") -replace $args[2], "***"
    Write-Warning "Failed $($co). 'az $cmd' failed with $($LastExitCode) - 2nd attempt..."
            & az $argumentList 2>&1 | ForEach-Object { "$_" }
            if ($LastExitCode -ne 0) {
    throw "Error: Failed $($co). 'az $cmd' 2nd attempt failed with $($LastExitCode)."
            }
        }
        Write-Host "Completed $($co)."
    }
}
if ($script:ReadOnly.IsPresent) {
    return
}
# Wait for copy jobs to finish for this repo.
if ($jobs.Count -ne 0) {
    Write-Host "Waiting for copy jobs for $($targetRegistry.Registry)."
    # Wait until all jobs are completed
    Receive-Job -Job $jobs -WriteEvents -Wait | Write-Verbose
    $jobs | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        throw "Error: Copying $($_.Name). resulted in $($_.State)."
    }
}
Write-Host "All copy jobs completed for $($targetRegistry.Registry)." 

# -------------------------------------------------------------------------
# Create tasks from task artifact and run them first time
foreach ($taskArtifact in $taskArtifacts) {
    & (Join-Path $PSScriptRoot "task-run-all.ps1") -TaskArtifact $taskArtifact `
        -Subscription $targetRegistry.Subscription `
        -IsLatest:$script:IsLatest -IsMajorUpdate $script:IsMajorUpdate
    if ($LastExitCode -ne 0) {
        throw "Failed to run tasks from $taskArtifact."
    }
}
# -------------------------------------------------------------------------
