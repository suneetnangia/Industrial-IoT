@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set current-path=%~dp0
set script-name=%~nx0
rem // remove trailing slash
set current-path=%current-path:~0,-1%
set build_root=%current-path%\..

set _resourceGroup=
set _deploy=1
set _build=1
set _clean=

:args-loop
if "%1" equ "" goto :args-done
if "%1" equ "--clean" goto :arg-clean
if "%1" equ  "-c" goto :arg-clean
if "%1" equ "--skip-deploy" goto :arg-no-deploy
if "%1" equ "--skip-build" goto :arg-no-build
if "%1" equ "--resourcegroup" goto :arg-resourcegroup
if "%1" equ  "-g" goto :arg-resourcegroup
if "%1" equ "--help" goto :usage
if "%1" equ  "-h" goto :usage
goto :usage
:args-continue
shift
goto :args-loop

:usage
echo %script-name% [options]
echo options:
echo -g --resourcegroup Resource group name.
echo -c --clean        print a trace of each command.
echo    --skip-deploy  Do not deploy.
echo    --skip-build   Skip building
echo -x --xtrace        print a trace of each command.
echo -h --help         This help.
exit /b 1

:arg-clean
set _clean=1
goto :args-continue

:arg-no-deploy
set _deploy=
goto :args-continue
:arg-no-build
set _build=
goto :args-continue
:arg-resourcegroup
shift
set _resourceGroup=%1
goto :args-continue
:args-done
goto :main

:main
if not "%_clean%" == "1" goto :build
echo Clean...
cmd /c az group delete -y -g %_resourceGroup% > nul 2> nul
goto :build

:build
if not "%_build%" == "1" goto :deploy
echo Build...
set __args=
set __args=%__args% -Subscription IOT-OPC-WALLS
set __args=%__args% -ResourceGroupLocation westeurope
set __args=%__args% -ResourceGroupName %_resourceGroup% 
pushd %build_root%\tools\scripts
powershell ./build.ps1 %__args%
popd
if !ERRORLEVEL! == 0 goto :deploy
echo Build failed.
goto :done

:deploy
if not "%_deploy%" == "1" goto :done
echo Deploy...
set __args=%__args% -ApplicationName %_resourceGroup%
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
