<#
 .SYNOPSIS
    Builds multiarch containers from the container.json file in the
    path.

 .DESCRIPTION
    The script requires az to be installed and already logged on to a 
    subscription.  This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

 .PARAMETER Path
    The folder to build the container content in (Required if no 
    Container object is provided)
 .PARAMETER Container
    The container description object if already built before (Optional)

 .PARAMETER Registry
    The name of the registry
 .PARAMETER Subscription
    The subscription to use - otherwise uses default

 .PARAMETER Debug
    Build debug and include debugger into images (where applicable)
 .PARAMETER Fast
    Perform fast build. 
#>

Param(
    [string] $Path = $null,
    [object] $Container = $null,
    [string] $Registry = $null,
    [string] $Subscription = $null,
    [switch] $Debug,
    [switch] $Fast
)

# -------------------------------------------------------------------------
# Build and publish dotnet output if no container definition provided
if (!$script:Container) {
    if ([string]::IsNullOrEmpty($Path)) {
        throw "No docker folder specified."
    }
    if (!(Test-Path -Path $Path -PathType Container)) {
        $Path = Join-Path (& (Join-Path $PSScriptRoot "get-root.ps1") `
            -fileName $Path) $Path
    }
    $Path = Resolve-Path -LiteralPath $Path
    $script:Container = & (Join-Path $PSScriptRoot "dotnet-build.ps1") `
        -Path $Path -Debug:$script:Debug -Fast:$script:Fast -Clean
    if (!$script:Container) {
        return
    }
}
if ($script:Fast.IsPresent -and (!$script:Container.metadata.buildAlways)) {
    Write-Warning "Using fast build - Skipping $($script:Container.name)."
    return
}

# -------------------------------------------------------------------------
# Collect image information
$namespace = ""
if (!$script:Fast.IsPresent) {
    # Building as part of ci/cd pipeline. Try get branch name
    $branchName = $env:BUILD_SOURCEBRANCH
    if (![string]::IsNullOrEmpty($branchName)) {
        if ($branchName.StartsWith("refs/heads/")) {
            $branchName = $branchName.Replace("refs/heads/", "")
        }
        else {
            Write-Warning "'$($branchName)' is not a branch."
            $branchName = $null
        }
    }
    if ([string]::IsNullOrEmpty($branchName)) {
        try {
            $argumentList = @("rev-parse", "--abbrev-ref", "HEAD")
            $branchName = (& "git" $argumentList 2>&1 | ForEach-Object { "$_" });
            if ($LastExitCode -ne 0) {
                throw "git $($argumentList) failed with $($LastExitCode)."
            }
        }
        catch {
            Write-Warning $_.Exception
            $branchName = $null
        }
    }

    if ([string]::IsNullOrEmpty($branchName) -or ($branchName -eq "HEAD")) {
        Write-Warning "Not building from a branch - skip image build."
        return
    }

    # Set namespace name based on branch name
    $namespace = $branchName
    if ($namespace.StartsWith("feature/")) {
        # dev feature builds
        $namespace = $namespace.Replace("feature/", "")
    }
    elseif ($namespace.StartsWith("release/") -or ($namespace -eq "main")) {
        $namespace = "public"
        if ([string]::IsNullOrEmpty($script:Registry)) {
            # Release and Preview builds go into staging
            $script:Registry = "industrialiot"
            Write-Warning "Using $($script:Registry).azurecr.io."
        }
    }
    $namespace = $namespace.Replace("_", "/")
    $namespace = $namespace.Substring(0, [Math]::Min($namespace.Length, 24))
    $namespace = "$($namespace)/"
}

if ([string]::IsNullOrEmpty($script:Registry)) {
    $script:Registry = $env.BUILD_REGISTRY
    if ([string]::IsNullOrEmpty($script:Registry)) {
        # Feature builds by default build into dev registry
        $script:Registry = "industrialiotdev"
        Write-Warning "Using $($script:Registry).azurecr.io."
    }
}

# get and set build information from gitversion, git or version content
$sourceTag = $env:Version_Prefix
$revision = $env:Version_Full
if ([string]::IsNullOrEmpty($sourceTag)) {
    try {
        $version = & (Join-Path $PSScriptRoot "get-version.ps1")
        $sourceTag = $version.Prefix
        $revision = $version.Full
    }
    catch {
        # build as latest if not building from ci/cd pipeline
        if (!$script:Fast.IsPresent) {
            Write-Warning "Unable to determine version - skip image build."
            return
        }
        $sourceTag = "latest"
        $revision = ""
    }
}
$tagPostfix = ""
if ($script:Container.debug -and (!$script:Fast.IsPresent)) {
    $tagPostfix = "-debug"
}

# -------------------------------------------------------------------------
# Get registry information
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
$argumentList = @("acr", "show", "--name", $script:Registry, 
    "--subscription", $script:Subscription)
$registryInfo = (& "az" $argumentList 2>&1 `
    | ForEach-Object { "$_" }) | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}
$resourceGroup = $registryInfo.resourceGroup
Write-Debug "Using resource group $($resourceGroup)"
# get credentials
$argumentList = @("acr", "credential", "show", "--name", $script:Registry, 
    "--subscription", $script:Subscription)
$credentials = (& "az" $argumentList 2>&1 `
    | ForEach-Object { "$_" }) | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}

$user = $credentials.username
$password = $credentials.passwords[0].value
Write-Debug "Using User name $($user) and passsword ****"

# -------------------------------------------------------------------------
# Publish runtime artifacts to registry
$argumentList = @("pull", "ghcr.io/deislabs/oras:v0.11.1")
& docker $argumentList 2>&1 | ForEach-Object { "$_" }
$jobs = @()
$script:Container.runtimes.Keys | ForEach-Object {
    $runtime = $script:Container.runtimes.Item($_)

    $created = $(Get-Date -Format "o")
    $root = (Split-Path -Path $runtime.artifact -Parent)
    $workspace = Join-Path $root "workspace"

    # content of the artifact image
    $folderName = "$($runtime.runtimeId)$($tagPostfix)"
    $content = Join-Path $workspace $folderName
    Remove-Item $content -Recurse -Force -ErrorAction SilentlyContinue

    $runtimeParts = $($runtime.runtimeId).Split('-')
    $os = $runtimeParts[0]
    # Create a from scratch artifact image using oras and magic
    if ($os -eq "win") {
        $os = "windows"

        New-Item -ItemType "directory" -Path (Join-Path $content "Files") `
            -Name "bin" -Force | Out-Null
        Copy-Item -Recurse -Path (Join-Path $runtime.artifact "*") `
            -Destination (Join-Path (Join-Path $content "Files") "bin")
        
  # see https://github.com/buildpacks/imgutil/blob/main/layer/windows_baselayer.go
        $files = Join-Path (Join-Path (Join-Path (Join-Path `
            $content "Files") "Windows") "System32") "config"
        New-Item -Force -Path $files -ItemType "file" -Name "DEFAULT"   | Out-Null
        New-Item -Force -Path $files -ItemType "file" -Name "SAM"       | Out-Null
        New-Item -Force -Path $files -ItemType "file" -Name "SECURITY"  | Out-Null
        New-Item -Force -Path $files -ItemType "file" -Name "SOFTWARE"  | Out-Null
        New-Item -Force -Path $files -ItemType "file" -Name "SYSTEM"    | Out-Null
    $bcdenc  = "H4sIAAAAAAAC/+yaPWwbZRjH/5cmJAQoF/tcBanDoUSwcJXPvri+KaJN2gAlQZBWD"
    $bcdenc += "Bm4j9fkajuxbAOtqqCMGTuwMCB5YOhCxcYICxJiQB4Zu9EBoUgsgYEXPfeR88dZbR"
    $bcdenc += "FDpT6/6HyP3/d5/T73PH/Feh+5LT6uKQpA14Oj/lcvff0zmZhBBNk6oheyd7CKVez"
    $bcdenc += "gOjZxGTvooo0AHuqh3UQLO1jDOq7gTVzHNWyDeVr5Pqj+zVlgGIZhGIZhGIZ5Nth1"
    $bcdenc += "g73QUNOxpA9Adk9KuVd/A/rrl75Mxn6YBaaS9QuAlFKSTffD+H4uY68XASwvL7/3/"
    $bcdenc += "tb21oWNt27Q2E//SNmpA7SOrhcAnFcABdNfQAFUJVqrgfb8HfPhu0W8gikoURAzOo"
    $bcdenc += "BXyZ5fpPeHY+MZ/ksT/Jdi/1W8POSvp/7q2Di0yD+KdSZHr/Na5Ds4NvFzh3zPhH2"
    $bcdenc += "XEZ/hzwE2zrJ2GYZhGIZhGIZhmCc8/6vD5/9BovO/PnT+1wfmZQwdV++q0Rk+6Qck"
    $bcdenc += "vouxTWf7NdHx2kGrG+ynbYfGrgJdBfzyj78cSyl7KtCP4+lLKT+tq5imczpA9/B3C"
    $bcdenc += "FeCdvMzpy3e3feDWiD8095F6D8b7nmsRr50vSNubzpNEc5fwmWsoTjyF3FvwvMm/Y"
    $bcdenc += "4NLbvfcS0jd7MAttybwut28FBK2didOn1OdQH4Y/3+20cZ+9Fcsh/yj99feQ3AnYp"
    $bcdenc += "T8cya6Rortm8Zpikcw7bKVcO2iiVRcVzftqsHad4PF4AP/lz9K6vONDdaZ5q4lRuv"
    $bcdenc += "81xcm0fVeS4XPf8JPUsuqdd0WN8z0NWkvtu3W2KS/iiuuC2EWxPykyVninG9IZpir"
    $bcdenc += "9tJxpK6JHH1coB9/7d7Wfv2ctn5OMqP5+MsgPMD+5qlImEl88fhvgoW88DSN899R/"
    $bcdenc += "m4m0/1S2u/zaf6jeMO5118ggAN+GjBCX9708EFBNinWB6hpw8LT6gn2xdOtVLyjBX"
    $bcdenc += "P9w1LXCwajueZRq1ccsuW5VsX7ZWDNI+Jnvp54Orn3atZeaS5rDz2tf+uq4+0VFe/"
    $bcdenc += "asO6moL6WLrq51Nd9Qv/j65O49Im6+pEy87Hg0K2rjYH9i2VQ12VR3XVKgAn8zduU"
    $bcdenc += "j4eFlJd0dq5c+O6ov97d1CBgwo8mKjBhAsDK7Dhw4IBEyYEHBiwYaGMamwVUYIIV7"
    $bcdenc += "rwYcNGFQfp98fz/B3LMAzDMAzzNPFvAAAA///Odx8+ADAAAA=="
        $in = New-Object System.IO.MemoryStream(,`
            [Convert]::FromBase64String($bcdenc))
        $gzip = New-Object System.IO.Compression.GzipStream $in, `
            ([IO.Compression.CompressionMode]::Decompress)
        $bcd = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path `
            $content "UtilityVM") "Files") "EFI") "Microsoft") "Boot"
        New-Item -Force -Path $bcd -ItemType "directory" | Out-Null
	    $out = New-Object System.IO.FileStream (Join-Path $bcd "BCD"), `
            ([IO.FileMode]::Create),`
            ([IO.FileAccess]::Write), ([IO.FileShare]::None)
	    $gzip.CopyTo($out)
        $gzip.Close()
		$in.Close()
        $out.Close()
    }
    else {
        New-Item -ItemType "directory" -Path $content -Name "bin" -Force | Out-Null
        Copy-Item -Recurse -Path (Join-Path $runtime.artifact "*") `
            -Destination (Join-Path $content "bin") 
    }

    $arch = $runtimeParts[$runtimeParts.Count - 1]
    if ($arch -eq "x64") {
        $arch = "amd64"
    }
    $configFile = "$($folderName).config"
    @{
        "created" = $created
        "author" = "Microsoft"
        "architecture" = "$($arch.ToLower())"
        "os" = "$($os.ToLower())"
        "rootfs" = @{
            "diff_ids" = @("%sha%")
            "type" = "layers"
        }
    } | ConvertTo-Json `
      | Out-File -Encoding ascii -FilePath (Join-Path $workspace $configFile)
    
    $annotationFile = "$($folderName).annotations"
#https://github.com/oras-project/oras-www/blob/main/docs/documentation/annotations.md
    @{
        "$($runtime.runtimeId).tar.gz" = @{
            # https://github.com/opencontainers/image-spec/blob/master/annotations.md
            # "org.opencontainers.image.title" = $($script:Container.name)
            "org.opencontainers.image.url" = "https://github.com/Azure/Industrial-IoT"
            "org.opencontainers.image.licenses" = "MIT"
            "org.opencontainers.image.revision" = $revision
            "org.opencontainers.image.version" = $sourceTag
            "org.opencontainers.image.source" = $branchName
            "org.opencontainers.image.vendor" = "Microsoft"
            "org.opencontainers.image.created" = $created
            "io.deis.oras.content.digest" = "%sha%"
            "io.deis.oras.content.unpack" = "true"
        }
    } | ConvertTo-Json `
      | Out-File -Encoding ascii -FilePath (Join-Path $workspace $annotationFile)

    $artifact = "$($script:Registry).azurecr.io/$($namespace)"
    $artifact = "$($artifact)$($script:Container.name)"
    $artifact = "$($artifact):$($sourceTag)$($tagPostfix)"
    $artifact = "$($artifact)-artifact-$($runtime.runtimeId)"
    #
    # create push shell script to tar and set the sha1 hashes correctly so 
    # docker when pulling the artifact validates the content hash correctly.
    # see https://containers.gitbook.io/build-containers-the-hard-way/
    # Uses Linux tools from oras container for platform independence.
    #
    $pushscript = "$($folderName).push.sh"
    [IO.File]::WriteAllText((Join-Path $workspace $pushscript), (@"
#!/bin/sh -e
    cwd=`$(pwd)
    rm -f $($runtime.runtimeId).tar
    cd $($folderName) ; tar -cf `$cwd/$($runtime.runtimeId).tar *
    cd `$cwd
    sha=`$(sha256sum $($runtime.runtimeId).tar | awk '{print `$1}')
    echo "$($runtime.runtimeId).tar content hash: sha256:`$sha"
    sed "s/%sha%/sha256:`$sha/" $configFile > $($configFile).json
    rm -f $($runtime.runtimeId).tar.gz
    gzip $($runtime.runtimeId).tar
    sha=`$(sha256sum $($runtime.runtimeId).tar.gz | awk '{print `$1}')
    echo "$($runtime.runtimeId).tar.gz layer hash: sha256:`$sha"
    sed "s/%sha%/sha256:`$sha/" $annotationFile > $($annotationFile).json
    oras push $artifact $($runtime.runtimeId).tar.gz -u $user -p "`$1" \
        --manifest-config $($configFile).json \
        --manifest-annotations $($annotationFile).json
    echo "$($runtime.runtimeId).tar.gz successfully pushed as $artifact."
"@ -replace "`r`n", "`n"))
    
    $argumentList = @("run", "--rm", "-v", "$($workspace):/workspace", 
        "--entrypoint", "sh", "ghcr.io/deislabs/oras:v0.11.1",
        $pushscript, $password)
    Write-Host "Starting job to upload $artifact from $workspace..."
    $jobs += Start-Job -Name $artifact -ArgumentList $argumentList -ScriptBlock {
        $argumentList = $args
        & docker $argumentList 2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            $cmd = $($argumentList | Out-String)
            Write-Warning "docker $cmd failed with $LastExitCode - 2nd attempt..."
            & docker $argumentList 2>&1 | ForEach-Object { "$_" }
            if ($LastExitCode -ne 0) {
                throw "Error: 'docker $cmd' 2nd attempt failed with $LastExitCode."
            }
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
        throw "ERROR: Pushing artifact $($_.Name) resulted in $($_.State)."
    }
}
Write-Host "All artifact jobs completed successfully."
Write-Host ""

# -------------------------------------------------------------------------
# Create dockerfile and acr task definitions and upload as buildtask artifact
$platforms = @(
    @{
        runtimeId = "linux-arm"
        platform = "linux/arm"
        image = "mcr.microsoft.com/dotnet/core/runtime-deps:3.1"
        platformTag = "linux-arm32v7"
        runtimeOnly = "RUN chmod +x $($script:Container.assemblyName)"
        entryPoint = "[`"./$($script:Container.assemblyName)`"]"
    }
    @{
        runtimeId = "linux-musl-arm64"
        platform = "linux/arm64"
        image = "mcr.microsoft.com/dotnet/core/runtime-deps:3.1-alpine-arm64v8"
        platformTag = "linux-arm64v8"
        runtimeOnly = "RUN chmod +x $($script:Container.assemblyName)"
        entryPoint = "[`"./$($script:Container.assemblyName)`"]"
    }
    @{
        runtimeId = "linux-musl-x64"
        platform = "linux/amd64"
        image = "mcr.microsoft.com/dotnet/core/runtime-deps:3.1-alpine"
        platformTag = "linux-amd64"
        runtimeOnly = "RUN chmod +x $($script:Container.assemblyName)"
        always = $true
        entryPoint = "[`"./$($script:Container.assemblyName)`"]"
    }
    @{
        runtimeId = "win-x64"
        platform = "windows/amd64"
        image = "mcr.microsoft.com/windows/nanoserver:1809"
        platformTag = "nanoserver-amd64-1809"
        always = $true
        entryPoint = "[`"$($script:Container.assemblyName).exe`"]"
    }
    @{
        runtimeId = "win-x64"
        platform = "windows/amd64"
        image = "mcr.microsoft.com/windows/nanoserver:1909"
        platformTag = "nanoserver-amd64-1909"
        entryPoint = "[`"$($script:Container.assemblyName).exe`"]"
    }
)

$taskContext = $script:Container.name.Replace('/', '-')
$taskContext = Join-Path $script:Container.publishPath "$($taskContext)-context"
New-Item -ItemType Directory -Force -Path $taskContext | Out-Null

$tasks = @{}
$platforms | ForEach-Object {
    $platformInfo = $_
    $platform = $platformInfo.platform.ToLower()
    $platformTag = $platformInfo.platformTag.ToLower()
    $runtimeId = $platformInfo.runtimeId
    $baseImage = $platformInfo.image
    
    # Create docker file
    $environmentVars = @("ENV DOTNET_RUNNING_IN_CONTAINER=true")
    # Only build windows and linux in fast mode
    if ($script:Fast.IsPresent -and (!$platformInfo.always)) {
        return
    }
    #
    # Check for overridden base image name - e.g. aspnet core images
    # this script only supports portable and defaults to dotnet entry 
    # point
    #
    if (![string]::IsNullOrEmpty($script:Container.metadata.base)) {
        $baseImage = $script:Container.metadata.base
        $runtimeId = $null
    }
    if ([string]::IsNullOrEmpty($runtimeId)) {
        $runtimeId = "portable"
    }
    # 
    # Now index into the runtimes to get the location of the 
    # binaries and assembly entrypoint information for the chosen runtime.
    #
    $runtime = $script:Container.runtimes[$runtimeId]
    if (!$runtime) {
        Write-Warning "No runtime build for $runtimeId!"
        return
    }
    $runtimeOnly = ""
    if (![string]::IsNullOrEmpty($platformInfo.runtimeOnly)) {
        $runtimeOnly = $platformInfo.runtimeOnly
    }
    if ($runtimeId -eq "portable") {
        $runtimeOnly = ""
        $entryPoint = "[`"dotnet`", `"$($script:Container.assemblyName).dll`"]"
    }
    else {
        $entryPoint = $platformInfo.entryPoint
    }
    $exposes = ""
    if ($script:Container.metadata.exposes -ne $null) {
        $script:Container.metadata.exposes | ForEach-Object {
            $exposes = "$("EXPOSE $($_)" | Out-String)$($exposes)"
        }
        $environmentVars += "ENV ASPNETCORE_FORWARDEDHEADERS_ENABLED=true"
    }
    $workdir = ""
    if ($script:Container.metadata.workdir -ne $null) {
        $workdir = "WORKDIR /$($script:Container.metadata.workdir)"
    }
    if ([string]::IsNullOrEmpty($workdir)) {
        $workdir = "WORKDIR /app"
    }

    $artifact = "$($script:Registry).azurecr.io/$($namespace)"
    $artifact = "$($artifact)$($script:Container.name)"
    $artifact = "$($artifact):$($sourceTag)$($tagPostfix)"
    $artifact = "$($artifact)-artifact-$($runtime.runtimeId)"

    $dockerFileContent = @"
FROM $($baseImage)

$($exposes)

$($workdir)

COPY --from=$($artifact) bin .
$($runtimeOnly)

$($environmentVars | Out-String)

ENTRYPOINT $($entryPoint)

"@
    $dockerFile = "Dockerfile.$($platformTag)$($tagPostfix)"
    Write-Host "Writing $dockerFile to $taskContext"
    $dockerFileContent | Out-File -Encoding ascii `
        -FilePath (Join-Path $taskContext $dockerFile)

    # Create image build definition 
    $image = "$`Registry/$($namespace)$($script:Container.name)"
    $image = "$($image):$($sourceTag)-$($platformTag)$($tagPostfix)"

    $os = $platform.Split('/')[0]
    $taskname = $os
    if ($taskname -eq "windows") {
        # Fixes acr ReservedResourceName for trademarked or reserved words
        $taskname = "win" 
    }
    $taskname = "$($taskname)-$($sourceTag.Replace('.', '-'))$($tagPostfix)"
    if (!$tasks[$taskname]) {
        $tasks[$taskname] = @{
            annotation = @{
                "com.microsoft.azure.acr.task.name" = $taskname
                "com.microsoft.azure.acr.task.platform" = $os
            }
            images = @()
            taskyaml = @"
version: v1.1.0
steps:

"@
        }
    }

    # Add build step
    Write-Host "Adding $image build step for $platform with $artifact..."
    $tasks[$taskname].images += $image
    $tasks[$taskname].taskyaml += @"
  - build: -t $image -f $dockerFile --platform=$platform .

"@
}

# Add push task and collect images for manifest
$manifestImages = @()
$tasks.Keys | ForEach-Object {
    $buildtask = $tasks.Item($_)
    $buildtask.taskyaml += @"
  - push:

"@
    $buildtask.images | ForEach-Object {
        $buildtask.taskyaml += @"
    - $_

"@
        $manifestImages += $_
    }
}

# -------------------------------------------------------------------------
# Add step to create a new manifest list from all images.
#
# The problem with this approach is that images are built on multiple 
# platforms, yet the manifest list must contain all of these images.
# If one platform has not built yet, the images are missing and the 
# creation of the list will fail (image not available yet).
# We thus execute the first runs in parallel and have enough retries
# to account for manifests still not having been pushed by other tasks.
#
if ($manifestImages.Count -eq 0) {
    Write-Host "Nothing to build."
    return
}
$fullImageName = "$`Registry/$($namespace)$($script:Container.name)"
$tasks.Keys | ForEach-Object {
    $buildtask = $tasks.Item($_)
    $buildtask.taskyaml += "  - cmd: docker manifest create --amend "
    $buildtask.taskyaml += "$($fullImageName):$($sourceTag)$($tagPostfix)"
    $manifestImages | ForEach-Object { $buildtask.taskyaml += " $_" }
    $buildtask.taskyaml += @"

    retries: 60
    retryDelay: 10
  - cmd: docker manifest push --purge $($fullImageName):$($sourceTag)$($tagPostfix)
    retries: 1

"@
}

# -------------------------------------------------------------------------
# Upload the task context as artifact into registry
$annotations = @{}
$tasks.Keys | ForEach-Object {
    $buildtask = $tasks.Item($_)
    $taskfile = "$_.yaml"
    $buildtask.taskyaml | Out-File -Encoding ascii -FilePath `
        (Join-Path $taskContext $taskfile)
    $buildtask.taskyaml | Out-Host
    $annotations[$taskfile] = $buildtask.annotation
}

Write-Host "Uploading task context $taskContext ..."
$taskArtifact = "$($script:Registry).azurecr.io/$($namespace)"
$taskArtifact = "$($taskArtifact)$($script:Container.name)"
$taskArtifact = "$($taskArtifact):$($sourceTag)$($tagPostfix)-tasks"

$argumentList = @("run", "--rm", "-v", "$($taskContext):/workspace", 
    "ghcr.io/deislabs/oras:v0.11.1", "push", $taskArtifact)
$annotationFile = "buildtask.annotations.json"
Remove-Item -Path (Join-Path $taskContext $annotationFile) -Force `
    -ErrorAction SilentlyContinue
$argumentList += (Get-ChildItem -Path $taskContext -File -Name)
$annotations | ConvertTo-Json | Out-File -Encoding ascii `
    -FilePath (Join-Path $taskContext $annotationFile)
$annotations | ConvertTo-Json | Out-Host
$argumentList += @("-u", $user, "-p", $password, "-v", 
    "--manifest-annotations", $annotationFile)

& docker $argumentList 2>&1 | ForEach-Object { "$_" }
if ($LastExitCode -ne 0) {
    $cmd = $($argumentList | Out-String)
    Write-Warning "docker $cmd failed with $LastExitCode - 2nd attempt..."
    & docker $argumentList 2>&1 | ForEach-Object { "$_" }
    if ($LastExitCode -ne 0) {
        throw "Error: 'docker $cmd' 2nd attempt failed with $LastExitCode."
    }
}
Write-Host "Task context uploaded successfully as $taskArtifact."

# -------------------------------------------------------------------------
# Create tasks from task artifact
& (Join-Path $PSScriptRoot "acr-task.ps1") -TaskArtifact $taskArtifact `
    -Subscription $script:Subscription

# -------------------------------------------------------------------------
