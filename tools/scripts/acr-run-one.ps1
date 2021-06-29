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
 .PARAMETER NoBuild
    Do not build images, just build manifest
 .PARAMETER NoManifest
    Do not build the manifest, only the input images
 .PARAMETER NoWait
    Do not wait for results
#>

Param(
    [Parameter(Mandatory = $true)] [string] $TaskName,
    [Parameter(Mandatory = $true)] [object] $RegistryInfo,
    [switch] $NoManifest,
    [switch] $NoBuild,
    [switch] $NoWait
)

# -------------------------------------------------------------------------
# Get task logs
function GetLogs {
    Param( 
        [string] $RunId,
        [string] $Prefix
    )
    $argumentList = @("acr", "task", "logs", "--run-id", $RunId,
        "--registry", $script:RegistryInfo.Registry,
        "--resource-group", $script:RegistryInfo.ResourceGroup,
        "--subscription", $script:RegistryInfo.Subscription
    )  
    return & az $argumentList 2>&1 | ForEach-Object { "$Prefix : $_" } 
}

# -------------------------------------------------------------------------
# Get task status
function GetStatus {
    Param( 
        [string] $RunId
    )
    # check the started run completes with success
    $argumentList = @("acr", "task", "show-run", "--run-id", $RunId,
        "--registry", $script:RegistryInfo.Registry,
        "--resource-group", $script:RegistryInfo.ResourceGroup,
        "--subscription", $script:RegistryInfo.Subscription
    )
    for ($i = 0; $i -lt 5; $i++) {
        $result = (& az $argumentList 2>&1 | ForEach-Object { "$_" })
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList -join " ")
            Write-Warning "Error: 'az $cmd' failed with $LastExitCode."
            Start-Sleep -Seconds 1
            continue
        }
        $runResult = $result | ConvertFrom-Json
        return $runResult.status
    }
    throw "Error: 'az $cmd' failed with $LastExitCode."
}

# -------------------------------------------------------------------------
# run the task
$startTime = $(Get-Date)
$runTime = $null
Write-Verbose "Starting task run for $($script:TaskName)..."
# enable retries for resiliency
$success = $false
$t = "Task $script:TaskName"
for ($i = 0; $i -lt 5; $i++) {
    $argumentList = @("acr", "task", "run", "--no-wait",
        "--name", $script:TaskName,
        "--registry", $script:RegistryInfo.Registry,
        "--resource-group", $script:RegistryInfo.ResourceGroup,
        "--subscription", $script:RegistryInfo.Subscription
    )
    if ($script:NoManifest.IsPresent) {
        $argumentList += "--set"
        $argumentList += "NoManifest=1"
    }
    if ($script:NoBuild.IsPresent) {
        $argumentList += "--set"
        $argumentList += "NoBuild=1"
    }
    $result = (& az $argumentList 2>&1 | ForEach-Object { "$_" })

    $runCmd = $($argumentList -join " ")
    $t = "Task $script:TaskName ($i)"
    if ($LastExitCode -ne 0) {
Write-Warning "Error: $($t) : 'az $runCmd' failed with $LastExitCode."
        Start-Sleep -Seconds 1
        continue
    }
    $run = $result | Select-Object -First 1 
    if (!$run.Contains("Queued a run with ID:")) {
        $result | ForEach-Object { Write-Warning "$($t) : $_" }
        Start-Sleep -Seconds 1
        continue
    }
    $run = $run.Split(':') | Select-Object -Last 1 
    $run = $run.Trim()
    $t = "$($t) (Run ID: $($run))"
    Write-Verbose "$($t) started."
    # Poll until the started run completes with success
    $retries = 0
    while ($true) {
        $status = GetStatus -RunId $run
        if ($status -eq "Queued") {
            Write-Verbose "$($t) queued - waiting to start..."
            Start-Sleep -Seconds 3
            continue
        }
        if (!$runTime) {
            $runTime = $(Get-Date)
        }
        if ($status -eq "Running") {
            Write-Verbose "$($t) in progress..."
            if ($script:NoWait.IsPresent -and ($retries -gt 1)) {
                # exit here and do not wait for completion
                # we just want to ensure the was started.
                return
            }
            Start-Sleep -Seconds 3
            $retries++
            continue
        }
        if ($status -eq "Succeeded") {
            # done - break out
            if ($VerbosePreference -ne "SilentlyContinue") {
                GetLogs -RunId $run -Prefix $t | Write-Verbose
            }
            $success = $true
            break 
        }
        if ($status -eq "Timeout") {
            if ($VerbosePreference -ne "SilentlyContinue") {
                GetLogs -RunId $run -Prefix $t | Write-Verbose
            }
            throw "Error: $($t) (az $runCmd) timed out."
        }
        if ($status -eq "Failed") {
            $runLogs = GetLogs -RunId $run -Prefix $t
            $dlf = $runLogs | Where-Object { 
                $_.Contains("Error: failed to download context.") 
            } | Select-Object -First 1
            if ($dlf) {
                Write-Warning "$($t) failed to download context."
                $runLogs | Write-Verbose
            }
            else {
                Write-Warning "$($t) (az $runCmd) failed."
                $runLogs | Write-Warning
            }
            break
        }
        
        Write-Warning "$($t) (az $runCmd) completed with '$($status)'"
        GetLogs -RunId $run -Prefix $t | Write-Warning
        break
    }
    if ($success) {
        # no more retries - break out
        break
    }
    Start-Sleep -Seconds 1
    Write-Host "Attempt #$i - re-start task $($script:TaskName) ..."
} 
if (!$success) {
    # end of for loop t retry.
    throw "Error: Task $($script:TaskName) failed after $($i) times."
}
# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
$runTime = $runTime - $startTime
$idleTime = "$($runTime.ToString("hh\:mm\:ss"))"
Write-Host "$($t) took $($elapsedString) (idle $($idleTime))..." 
# -------------------------------------------------------------------------
