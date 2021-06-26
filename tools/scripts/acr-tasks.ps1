<#
 .SYNOPSIS
    Creates Azure container registry task yaml definition files to
    build multiarch containers from either passed project objects
    or the the container.json files recursively expanded from path.

 .DESCRIPTION
    The script requires az to be installed and already logged on to
    an account. This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER Path
    The folder to build the container content in (Required if no 
    Container objects are provided)
 .PARAMETER Projects
    The project objects if already built before (Optional)
 .PARAMETER Output
    The root folder for all artifacts output (Optional).

 .PARAMETER Registry
    The name of the registry
 .PARAMETER Subscription
    The subscription to use - otherwise uses default

 .PARAMETER Debug
    Build debug and include debugger into images (where applicable)
 .PARAMETER Fast
    Perform a fast build. 
#>

Param(
    [string] $Path = $null,
    [array] $Projects = $null,
    [string] $Output = $null,
    [string] $Registry = $null,
    [string] $Subscription = $null,
    [switch] $Debug,
    [switch] $Fast,
    [switch] $SkipPublish
)

# -------------------------------------------------------------------------
# Get registry information
$registryInfo = & (Join-Path $PSScriptRoot "acr-login.ps1") `
    -Registry $script:Registry -Subscription $script:Subscription `
    -NoNamespace:$script:Fast
if (!$registryInfo) {
    throw "Failed to get registry information for $script:Registry"
}

# -------------------------------------------------------------------------
# Build all projects if no container definition provided
if ((!$script:Projects) -or ($script:Projects.Count -eq 0)) {
    if ($script:SkipPublish.IsPresent) {
        throw "-SkipPublish parameter not allowed with -Path."
    }
    [array]$script:Projects = & (Join-Path $PSScriptRoot "build-all.ps1") `
        -Path $script:Path -Output $script:Output `
        -Debug:$script:Debug -Fast:$script:Fast -Clean
    if ($LastExitCode -ne 0) {
        throw "build-all.ps1 failed with $($LastExitCode)."
    }
    if ((!$script:Projects) -or ($script:Projects.Count -eq 0)) {
        Write-Warning "Nothing to build under $($script:Path)."
        return
    }
    Write-Host ""
}

# -------------------------------------------------------------------------
# Publish artifacts from all built projects 
if (!$script:SkipPublish.IsPresent) {
    & (Join-Path $PSScriptRoot "acr-publish-all.ps1") `
        -Projects $script:Projects -RegistryInfo $registryInfo `
        -Debug:$script:Debug -Fast:$script:Fast
    Write-Host ""
}

# -------------------------------------------------------------------------
$startTime = $(Get-Date)
# Used to set the source tag 
$buildTag = $env:Version_Prefix
if ([string]::IsNullOrEmpty($buildTag)) {
    try {
        $version = & (Join-Path $PSScriptRoot "get-version.ps1")
        $buildTag = $version.Prefix
    }
    catch {
        # build as latest if not building from ci/cd pipeline
        if (!$script:Fast.IsPresent) {
            throw "Unable to determine version - skip image build."
        }
        $buildTag = "latest"
    }
}
Write-Host "Using version '$buildTag' as build tag."

# Create dockerfile and acr task definitions and upload as task artifact
$taskContext = $script:Output
if (!$taskContext) {
    $taskContext = $script:Path
}
$taskContext = Join-Path $taskContext "tasks"
Remove-Item $taskContext -Recurse -Force -ErrorAction SilentlyContinue `
    | Out-Null
New-Item -ItemType Directory -Force -Path $taskContext `
    | Out-Null

$tasks = @{}
foreach ($project in $script:Projects) {
    # Set postfix
    $tagPostfix = ""
    if ($project.Debug -and (!$script:Fast.IsPresent)) {
        $tagPostfix = "-debug"
    }
    $platforms = @(
        @{
            runtimeId = "linux-arm"
            platform = "linux/arm"
            images = @{
    default = "mcr.microsoft.com/dotnet/core/runtime-deps:3.1"
    aspnetcore = "mcr.microsoft.com/dotnet/aspnet:3.1"
            }
            platformTag = "linux-arm32v7"
            runtimeOnly = "RUN chmod +x $($project.AssemblyName)"
            entryPoint = "[`"./$($project.AssemblyName)`"]"
        }
        @{
            runtimeId = "linux-musl-arm64"
            platform = "linux/arm64"
            images = @{
    default = "mcr.microsoft.com/dotnet/core/runtime-deps:3.1-alpine-arm64v8"
    aspnetcore = "mcr.microsoft.com/dotnet/aspnet:3.1-alpine-arm64v8"
            }
            platformTag = "linux-arm64v8"
            runtimeOnly = "RUN chmod +x $($project.AssemblyName)"
            entryPoint = "[`"./$($project.AssemblyName)`"]"
        }
        @{
            runtimeId = "linux-musl-x64"
            platform = "linux/amd64"
            images = @{
    default = "mcr.microsoft.com/dotnet/core/runtime-deps:3.1-alpine"
    aspnetcore = "mcr.microsoft.com/dotnet/aspnet:3.1-alpine"
            }
            platformTag = "linux-amd64"
            runtimeOnly = "RUN chmod +x $($project.AssemblyName)"
            always = $true
            entryPoint = "[`"./$($project.AssemblyName)`"]"
        }
        @{
            runtimeId = "win-x64"
            platform = "windows/amd64"
            images = @{
    default = "mcr.microsoft.com/windows/nanoserver:1809"
    aspnetcore = "mcr.microsoft.com/dotnet/aspnet:3.1-nanoserver-1809"
            }
            platformTag = "nanoserver-amd64-1809"
            always = $true
            entryPoint = "[`"$($project.AssemblyName).exe`"]"
        }
        @{
            runtimeId = "win-x64"
            platform = "windows/amd64"
            images = @{
    default = "mcr.microsoft.com/windows/nanoserver:2004"
    aspnetcore = "mcr.microsoft.com/dotnet/aspnet:3.1-nanoserver-2004"
            }
            platformTag = "nanoserver-amd64-2004"
            entryPoint = "[`"$($project.AssemblyName).exe`"]"
        }
    )

    foreach ($platformInfo in $platforms) {
        $platform = $platformInfo.platform.ToLower()
        $platformTag = $platformInfo.platformTag.ToLower()
        $runtimeId = $platformInfo.runtimeId
        $baseImage = $platformInfo.images.default
    
        # Create docker file
        $environmentVars = @("ENV DOTNET_RUNNING_IN_CONTAINER=true")
        # Only build windows and linux in fast mode
        if ($script:Fast.IsPresent -and (!$platformInfo.always)) {
            break
        }
        #
        # Check for overridden base image name - e.g. aspnetcore images
        # we then default to dotnet entry point and consume portable
        #
        $base = $project.Metadata.base
        if (![string]::IsNullOrEmpty($base)) {
            $baseImage = $platformInfo.images[$base]
            if (!$baseImage) {
                Write-Warning "The requested $base image is not supported."
                break
            }
            $runtimeId = "portable"
        }
        # 
        # Now find the runtime object in the project runtimes to get the
        # location of the binaries for the chosen runtime.
        #
        $runtime = $project.Runtimes `
            | Where-Object { $_.runtimeId -eq $runtimeId } `
            | Select-Object -First 1
        if (!$runtime) {
            Write-Warning "No runtime build for $runtimeId!"
            break
        }
        $runtimeOnly = ""
        if (![string]::IsNullOrEmpty($platformInfo.runtimeOnly)) {
            $runtimeOnly = $platformInfo.runtimeOnly
        }
        if ($runtimeId -eq "portable") {
            $runtimeOnly = ""
            $entryPoint = "[`"dotnet`", `"$($project.AssemblyName).dll`"]"
        }
        else {
            $entryPoint = $platformInfo.entryPoint
        }
        $exposes = ""
        if ($project.Metadata.exposes) {
            $project.Metadata.exposes | ForEach-Object {
                $exposes = "$("EXPOSE $($_)" | Out-String)$($exposes)"
            }
            $environmentVars += "ENV ASPNETCORE_FORWARDEDHEADERS_ENABLED=true"
        }
        $workdir = ""
        if ($project.Metadata.workdir) {
            $workdir = "WORKDIR /$($project.Metadata.workdir)"
        }
        if ([string]::IsNullOrEmpty($workdir)) {
            $workdir = "WORKDIR /app"
        }

        $dockerFileContent = @"
FROM $($baseImage)

$($exposes)

$($workdir)

COPY $($runtimeId) .
$($runtimeOnly)

$($environmentVars | Out-String)

ENTRYPOINT $($entryPoint)

"@
        $buildContext = $script:Project.Name.Replace('/', '-')
        $dockerFile = "Dockerfile.$($buildContext)-$($platformTag)$($tagPostfix)"
        Write-Verbose "Writing $dockerFile to $taskContext ..."
        $dockerFileContent | Out-File -Encoding ascii `
            -FilePath (Join-Path $taskContext $dockerFile)

        $os = $platform.ToLower().Split('/')[0]
        $taskname = $os
        if ($taskname -eq "windows") {
            $taskname = "win"
        }
        # Create tasks per project and platform. 
        $sn = $script:Project.Name.Split('/') | Select-Object -Last 1
        $sn = $sn.Replace("industrial-iot-", "").Replace("iot-opc-", "")
        $sn = $sn.Substring(0, [Math]::Min($sn.Length, 35))
        $taskname = "$($sn)$($tagPostfix)-$($taskname)"
        if (!$tasks[$taskname]) {
            $tasks[$taskname] = @{
                annotation = @{
                    "com.microsoft.azure.acr.task.name" = $taskname
                    "com.microsoft.azure.acr.task.version" = $buildTag
                    "com.microsoft.azure.acr.task.platform" = $os
                }
                artifactCache = @{}
                stepIndex = 0
                images = @()
                repo = "`$Registry`$Namespace/$($project.Name)"
                taskyaml = @"
version: v1.1.0
stepTimeout: 2400
alias:
  values:
    SourceTag: $($buildTag)
    TargetTag: {{with `$tag := .Values.Tag}}"{{`$tag}}"{{else}}$($buildTag){{end}}
    Namespace: {{with `$ns := .Values.Namespace}}"/{{`$ns}}"{{else}}""{{end}}
steps:
  - id: oras
    when: ["-"]
    build: -t oras -f Dockerfile.oras.$($os) .

"@
            }
        }
       
        # Create image build definition 
        $image = "$($tasks[$taskname].repo):`$SourceTag"
        $image = "$($image)-$($platformTag)$($tagPostfix)"

        # Select artifact to include in image
        $artifact = "$($tasks[$taskname].repo):`$SourceTag-artifact"
        $artifact = "$($artifact)-$($runtimeId)$($tagPostfix)"

        $buildContext = "$($buildContext)$($tagPostfix)"

# Add steps to pull the artifact into the build context and build the dockerfile
Write-Verbose "Adding $($image) build step for $($platform) from $($artifact)..."
        $tasks[$taskname].stepIndex += 1
        $tasks[$taskname].images += @{
            image = $image
            index = $tasks[$taskname].stepIndex
        }

        # only add artifact pulling if required
        if (!$tasks[$taskname].artifactCache[$artifact]) {
            $tasks[$taskname].taskyaml += @"
  - id: artifact-$($tasks[$taskname].stepIndex)
    cmd: oras pull -o $($buildContext) -a $($artifact) 
    retries: 5
    retryDelay: 30
    when: ["oras"]

"@
            $tasks[$taskname].artifactCache[$artifact] = `
                "artifact-$($tasks[$taskname].stepIndex)"
        }
        $tasks[$taskname].taskyaml += @"
  - id: build-$($tasks[$taskname].stepIndex)
    when: ["$($tasks[$taskname].artifactCache[$artifact])"]
    build: -t $($image) -f $($dockerFile) --platform=$($platform) $($buildContext)
    retries: 2
    cache: $(if ($os -ne "linux") { "disabled" } else { "enabled" })

"@
    }
}

# Add push task to all tasks and the manifest creation steps
$tasks.Keys | ForEach-Object {
    $buildtask = $tasks.Item($_)
    if ($buildtask.images.Count -eq 0) {
        return
    }
    $buildtask.stepIndex += 1
    $buildtask.taskyaml += @"
  - id: push-$($buildtask.stepIndex)
    retries: 5
    retryDelay: 30
    push:

"@
    $when = ""
    $manifestImages = @()
    $buildtask.images | ForEach-Object {
        $buildtask.taskyaml += @"
    - $($_.image)

"@
        $manifestImages += $_.image
        $when = "$when,`"build-$($_.index)`""
    }
    $buildtask.taskyaml += @"
    when: [$($when.TrimStart(','))]

"@
    $manifests = $manifestImages -join " "
    $manifestList = "$($buildtask.repo):`$TargetTag$($tagPostfix)"
    #
    # One problem we have to address is that images are built on 
    # multiple platforms, yet the manifest list must contain all
    # images from all platforms.
    # If one platform has not built yet, the images are missing and
    # the creation of the list will fail (image not available yet).
    #
    # The base images that trigger re-build on update on the other
    # hand are only parsed from build steps in the task yamls which 
    # means we cannot create a seperate manifest build task  
    # triggered by the internal acr-builder engine.
    #
    # We therefore execute the first runs in parallel and add 
    # enough retries to account for manifests still not having been  
    # pushed by all other tasks. Subsequent runs will find images 
    # and can therefore execute in any order.
    # We also run the manifest step as a script so that the entire
    # script is re-run, rather than just the single manifest
    # command. A run will time out after 30 minutes.
    #
    $buildtask.taskyaml += @"
  - id: manifest-$($buildtask.stepIndex)
    when: ["push-$($buildtask.stepIndex)"]
    entryPoint: sh
    retries: 60
    retryDelay: 30
    cmd: |
      docker -c '
        {{with `$skipManifest := .Values.NoManifest}}
        echo "Skipping manifest step $($buildtask.stepIndex)"
        {{else}}
        docker manifest create $manifestList $manifests
        createError=`$?
        docker manifest push --purge $manifestList
        exit `$createError
        {{end}}
      '

"@
}

# -------------------------------------------------------------------------
# Add oras tool to the task
$orasRelease = "https://github.com/oras-project/oras/releases/download"
$orasVersion = "0.12.0"

# -------------------------------------------------------------------------
# Create windows dockerfile to build oras cmd step
$orasPkg = "oras_$($orasVersion)_windows_amd64.tar.gz"
$hash = "bdd9a3a7fa014d0f2676fed72bba90710cd80c1ae49e73a5bfcc944ee0ac4505"
@"
FROM mcr.microsoft.com/powershell:lts-nanoserver-1909
WORKDIR c:\\bin
RUN pwsh -Command \
  `$ErrorActionPreference = 'Stop'; \
  `$ProgressPreference = 'SilentlyContinue' ; \
  Invoke-WebRequest $($orasRelease)/v$($orasVersion)/$($orasPkg) \
    -OutFile $($orasPkg); \
  if ((Get-FileHash -Algorithm SHA256 $($orasPkg)).Hash \
    -ne '$hash') { throw }; \
  tar -xzf $($orasPkg) ; Remove-Item $($orasPkg) -Force
WORKDIR c:\\workspace
ENTRYPOINT ["c:\\bin\\oras.exe"]

"@ | Out-File -Encoding ascii `
    -FilePath (Join-Path $taskContext "Dockerfile.oras.windows")

# -------------------------------------------------------------------------
# Create linx dockerfile to build oras cmd step
$orasPkg = "oras_$($orasVersion)_linux_amd64.tar.gz"
$hash = "660a4ecd87414d1f29610b2ed4630482f1f0d104431576d37e59752c27de37ed"
@"
FROM mcr.microsoft.com/dotnet/core/runtime-deps:3.1-alpine
WORKDIR /bin
RUN wget $($orasRelease)/v$($orasVersion)/$($orasPkg) \
  && echo "$hash  $($orasPkg)" | sha256sum -c \
  && tar -xzf $($orasPkg) && rm -f $($orasPkg) \
  && chmod +x /bin/oras
WORKDIR /workspace
ENTRYPOINT  ["/bin/oras"]

"@ | Out-File -Encoding ascii `
    -FilePath (Join-Path $taskContext "Dockerfile.oras.linux")

# -------------------------------------------------------------------------
# Upload the task context as artifact into registry
$annotations = @{}
$tasks.Keys | ForEach-Object {
    $buildtask = $tasks.Item($_)
    $taskfile = "$_.yaml"
    $buildtask.taskyaml | Out-File -Encoding ascii `
        -FilePath (Join-Path $taskContext $taskfile)
    Write-Verbose $buildtask.taskyaml
    $annotations[$taskfile] = $buildtask.annotation
}

# Set the default image namespace
$namespace = $script:RegistryInfo.Namespace
if (![string]::IsNullOrEmpty($namespace)) {
    $namespace = "$($namespace)/"
}
else {
    $namespace = ""
}

$taskArtifact = "$($registryInfo.LoginServer)/$($namespace)tasks"
$taskArtifact = "$($taskArtifact):$($buildTag)-artifact$($tagPostfix)"
Write-Verbose "Uploading task context $taskContext as $taskArtifact..."

$argumentList = @("run", "--rm", "-v", "$($taskContext):/workspace", 
    "ghcr.io/deislabs/oras:v0.11.1", "push", $taskArtifact)
$annotationFile = "buildtask.annotations.json"
$argumentList += (Get-ChildItem -Path $taskContext -File -Name)
$annotations | ConvertTo-Json | Out-File -Encoding ascii `
    -FilePath (Join-Path $taskContext $annotationFile)
Write-Verbose $($annotations | ConvertTo-Json)
$argumentList += @("-u", $registryInfo.User, 
    "-p", $registryInfo.Password, "-v", 
    "--manifest-annotations", $annotationFile)

$pushLog = & docker $argumentList 2>&1
if ($LastExitCode -ne 0) {
    $pushLog | ForEach-Object { Write-Warning "$_" }
    $cmd = $($argumentList -join " ") -replace $registryInfo.Password, "***"
    Write-Warning "docker $cmd failed with $LastExitCode - 2nd attempt..."
    $pushLog = & docker $argumentList 2>&1
    if ($LastExitCode -ne 0) {
        $pushLog | ForEach-Object { Write-Warning "$_" }
        throw "Error: 'docker $cmd' 2nd attempt failed with $LastExitCode."
    }
}
Remove-Item $taskContext -Recurse -Force -ErrorAction SilentlyContinue `
    | Out-Null
$pushLog | ForEach-Object { Write-Verbose "$_" }

# -------------------------------------------------------------------------
$elapsedTime = $(Get-Date) - $startTime
$elapsedString = "$($elapsedTime.ToString("hh\:mm\:ss")) (hh:mm:ss)"
Write-Host "Uploading task context $($taskArtifact) took $($elapsedString)..." 

# -------------------------------------------------------------------------
# Create tasks from task artifact and run them first time
& (Join-Path $PSScriptRoot "acr-run-all.ps1") -TaskArtifact $taskArtifact `
    -Subscription $script:Subscription `
    -IsLatest:$script:Fast -RemoveNamespaceOnRelease:$script:Fast
if ($LastExitCode -ne 0) {
    throw "Failed to run tasks from $taskArtifact."
}
# -------------------------------------------------------------------------
