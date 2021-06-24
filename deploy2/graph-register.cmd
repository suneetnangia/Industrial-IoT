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
set _tenant=

:args-loop
if "%1" equ "" goto :args-done
if "%1" equ "--name" goto :arg-name
if "%1" equ  "-n" goto :arg-name
if "%1" equ "--tenant" goto :arg-tenant
if "%1" equ  "-t" goto :arg-tenant
if "%1" equ "--help" goto :usage
if "%1" equ  "-h" goto :usage
goto :usage
:args-continue
shift
goto :args-loop

:usage
echo %script-name% [options]
echo options:
echo -n --name          The Name prefix under which to register the 
echo                    applications (Mandatory).
echo -t --tenant        The Azure Active Directory Tenant to use.
echo -h --help          Shows this help.
exit /b 1

:arg-tenant
shift
set _tenant=%1
goto :args-continue
:arg-name
shift
set _name=%1
goto :args-continue

:args-done
if "%_name%" == "" goto :usage

rem // check and if needed install powershell and required modules
pushd %current-path%
call pwsh-setup.cmd
set __args=
set __args=%__args% -Name %_name%
set __args=%__args% -AsJson
if not "%_tenant%" == "" set __args=%__args% -TenantId %_tenant%
%PWSH% -ExecutionPolicy Unrestricted ./graph-register.ps1 %__args%
popd

