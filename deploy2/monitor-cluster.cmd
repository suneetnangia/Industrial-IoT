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

:args-loop
if "%1" equ "" goto :args-done
if "%1" equ "--name" goto :arg-name
if "%1" equ  "-n" goto :arg-name
if "%1" equ "--subscription" goto :arg-subscription
if "%1" equ  "-s" goto :arg-subscription
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
echo -g --resourcegroup Resource group where the cluster is deployed (Mandatory).
echo -n --name          Name of the cluster if more than one in the group.
echo -s --subscription  Subscription to use - if not provided, uses the default.
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

:args-done
if "%_resourceGroup%" == "" goto :usage
rem // check and if needed install powershell and required modules
pushd %current-path%
call pwsh-setup.cmd
set __args=
set __args=%__args% -ResourceGroup %_resourceGroup%
if not "%_name%" == "" set __args=%__args% -Cluster %_name%
if not "%_subscription%" == "" set __args=%__args% -Subscription %_subscription%
%PWSH% -ExecutionPolicy Unrestricted ./monitor-cluster.ps1 %__args%
popd
