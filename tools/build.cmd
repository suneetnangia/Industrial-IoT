@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set current-path=%~dp0
rem // remove trailing slash
set current-path=%current-path:~0,-1%
set build_root=%current-path%\..

set deploy=
if not "%1" == "--deploy" goto :args
set deploy=1
shift
:args
if not "%1" == "" goto :build
echo Must specify name of resource group.
goto :done

:build
set __args=
set __args=%__args% -Subscription IOT-OPC-WALLS
set __args=%__args% -ResourceGroupLocation westeurope
set __args=%__args% -ResourceGroupName %1 
pushd %build_root%\tools\scripts
powershell ./build.ps1 %__args%
popd
if !ERRORLEVEL! == 0 goto :deploy
echo Build failed.
goto :done

:deploy
if not "%deploy%" == "1" goto :done
set __args=%__args% -ApplicationName %1
pushd %build_root%\deploy
powershell ./deploy.ps1 -type all %__args% 
popd
if !ERRORLEVEL! == 0 goto :done
echo Deploy failed.
goto :done

:done
set __args=
set deploy=
goto :eof
