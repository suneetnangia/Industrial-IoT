@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set PWSH=powershell
set current-path=%~dp0
set script-name=%~nx0
rem // remove trailing slash
set current-path=%current-path:~0,-1%

set _name=
set _resourceGroup=
set _location=
set _subscription=
set _type=
set _minimal=
set _version=
set _tenant=
set _simulation=

:args-loop
if "%1" equ "" goto :args-done
if "%1" equ "--name" goto :arg-name
if "%1" equ  "-n" goto :arg-name
if "%1" equ "--subscription" goto :arg-subscription
if "%1" equ  "-s" goto :arg-subscription
if "%1" equ "--resourcegroup" goto :arg-resourcegroup
if "%1" equ  "-g" goto :arg-resourcegroup
if "%1" equ "--location" goto :arg-location
if "%1" equ  "-l" goto :arg-location

if "%1" equ "--type" goto :arg-type
if "%1" equ  "-t" goto :arg-type
if "%1" equ "--minimal" goto :arg-minimal
if "%1" equ "--version" goto :arg-version
if "%1" equ  "-v" goto :arg-version
if "%1" equ "--tenant" goto :arg-tenant
if "%1" equ  "-t" goto :arg-tenant
if "%1" equ "--simulation" goto :arg-simulation

if "%1" equ "--help" goto :usage
if "%1" equ  "-h" goto :usage
goto :usage
:args-continue
shift
goto :args-loop

:usage
echo %script-name% [options]
echo options:
echo -g --resourcegroup Resource group in which to deploy.
echo -s --subscription  Subscription to create the resource group in.
echo -l --location      Location to create the group in if it does not yet exist
echo -n --name          Name of deployment and application endpoint.
echo -t --type          Type of deployment (local, services, app, simulation, all)
echo    --minimal       Whether to not deploy optional services.
echo -v --version       Version to deploy
echo -t --tenant        Active directory tenant to use
echo    --simulation    Simulation profile to use.
echo -h --help          Shows this help.
exit /b 1

:arg-subscription
shift
set _subscription=%1
goto :args-continue
:arg-name
shift
set _name=%1
goto :args-continue
:arg-resourcegroup
shift
set _resourceGroup=%1
goto :args-continue
:arg-location
shift
set _location=%1
goto :args-continue
:arg-minimal
set _minimal=1
goto :args-continue
:arg-type
shift
set _type=%1
goto :args-continue
:arg-version
shift
set _version=%1
goto :args-continue
:arg-tenant
shift
set _tenant=%1
goto :args-continue
:arg-simulation
shift
set _simulation=%1
goto :args-continue

:args-done
rem // check and if needed install powershell and required modules
pushd %current-path%
call pwsh-setup.cmd
set __args=
if not "%_name%" == "" set __args=%__args% -ApplicationName %_name%
if not "%_subscription%" == "" set __args=%__args% -Subscription %_subscription%
if not "%_location%" == "" set __args=%__args% -ResourceGroupLocation %_location%
if not "%_resourceGroup%" == "" set __args=%__args% -ResourceGroupName %_resourceGroup%
if not "%_type%" == "" set __args=%__args% -Type %_type%
if not "%_version%" == "" set __args=%__args% -Version %_version%
if not "%_tenant%" == "" set __args=%__args% -TenantId %_tenant%
if not "%_simulation%" == "" set __args=%__args% -SimulationProfile %_simulation%
if not "%_minimal%" == "" set __args=%__args% -Minimal
%PWSH% -ExecutionPolicy Unrestricted %current-path%/deploy.ps1 %__args%
popd
