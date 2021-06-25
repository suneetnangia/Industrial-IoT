<#
 .SYNOPSIS
    Runs a task with the specified name in the specified registry.
 .DESCRIPTION
    The script requires az to be installed and already logged on to a 
    subscription.  This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER TaskName
    The task artifact OCI container image to use to boot strap all 
    tasks in the same registry. 
 .PARAMETER RegistryInfo
    The registry where the task was created (mandatory)
 .PARAMETER NoManifest
    Do not build the manifest, only the input images
 #>

Param(
    [Parameter(Mandatory = $true)] [string] $TaskName,
    [Parameter(Mandatory = $true)] [object] $RegistryInfo,
    [switch] $NoManifest
)

# -------------------------------------------------------------------------
# measure run
$startTime = $(Get-Date)
$commonArgs = @(
    "--name", $script:TaskName,
    "--registry", $script:RegistryInfo.Registry,
    "--resource-group", $script:RegistryInfo.ResourceGroup,
    "--subscription", $script:RegistryInfo.Subscription
)
# run the task
Write-Host "Starting task run for $($script:TaskName)..."

# enable retries for resiliency
$success = $false
for ($i = 0; $i -lt 5; $i++) {
    $argumentList = @("acr", "task", "run")
    if ($script:NoManifest.IsPresent) {
        $argumentList += "--set"
        $argumentList += "NoManifest=1"
    }
    $argumentList += $commonArgs
    $runLogs = & az $argumentList 2>&1 | ForEach-Object {
        return "$script:TaskName ($i) : $_"
    } 
    $cmd = $($argumentList -join " ")
    $t = "Task $script:TaskName ($i)"
    if ($LastExitCode -ne 0) {
        $runLogs | ForEach-Object { Write-Warning "$_" }
        Write-Warning "Error: $t : 'az $cmd' failed with $LastExitCode."
        Start-Sleep -Seconds 1
        continue
    }

    # check the started run completes with success
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
                break
            }
        }
        elseif ($status -eq "Succeeded") {
            # done - break out
            $success = $true
            break 
        }
    }
    if ($success) {
        # no more retries - break out
        break
    }
    Start-Sleep -Seconds 1
    Write-Host "Attempt #$i - re-starting task $($script:TaskName) ..."
} 
if (!$success) {
    # end of for loop t retry.
    throw "Error: Task $($script:TaskName) failed after $($i) times."
}

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Task $($script:TaskName) took $($elapsedString)..." 
# -------------------------------------------------------------------------
