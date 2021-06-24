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
if "%1" equ "--location" goto :arg-location
if "%1" equ  "-l" goto :arg-location
if "%1" equ "--help" goto :usage
if "%1" equ  "-h" goto :usage
goto :usage
:args-continue
shift
goto :args-loop

:usage
echo %script-name% [options]
echo options:
echo -g --resourcegroup Resource group if the identity is a managed identity.
echo                    If omitted, identity will be a service principal.
echo -l --location      Location to create the group in if it does not yet exist
echo -n --name          Name of the identity or service principal to create.
echo -s --subscription  Subscription to create the resource group and identity in
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

:args-done
rem // check and if needed install powershell and required modules
pushd %current-path%
call pwsh-setup.cmd
set __args=
if not "%_name%" == "" set __args=%__args% -Name %_name%
if not "%_subscription%" == "" set __args=%__args% -Subscription %_subscription%
if not "%_location%" == "" set __args=%__args% -Location %_location%
if not "%_resourceGroup%" == "" set __args=%__args% -ResourceGroup %_resourceGroup%
%PWSH% -ExecutionPolicy Unrestricted ./create-sp.ps1 %__args%
popd
