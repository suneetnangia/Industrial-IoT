@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set current-path=%~dp0
rem // remove trailing slash
set current-path=%current-path:~0,-1%
shift

if "%PWSH%" == "" set PWSH=powershell

:install-az
set test=
for /f %%i in ('%PWSH% -Command "Get-Module -ListAvailable -Name Az.* | ForEach-Object Name"') do set test=%%i
if not "%test%" == "" goto :install-az-done
echo Installing Az...
%PWSH% -Command "Install-Module -Name Az -AllowClobber -Scope CurrentUser"
echo Az installed.
:install-az-done
set test=

:install-az-msi
for /f %%i in ('%PWSH% -Command "Get-Module -ListAvailable -Name Az.ManagedServiceIdentity | ForEach-Object Name"') do set test=%%i
if not "%test%" == "" goto :install-az-msi-done
echo Installing Az.ManagedServiceIdentity...
%PWSH% -Command "Install-Module -Name Az.ManagedServiceIdentity -AllowClobber -Scope CurrentUser"
echo Az.ManagedServiceIdentity installed.
:install-az-msi-done
set test=

:install-mg
for /f %%i in ('%PWSH% -Command "Get-Module -ListAvailable -Name Microsoft.Graph.* | ForEach-Object Name"') do set test=%%i
if not "%test%" == "" goto :install-mg-done
echo Installing Microsoft.Graph...
%PWSH% -Command "Install-Module -Name Microsoft.Graph -AllowClobber -Scope CurrentUser"
echo Microsoft.Graph installed.
:install-mg-done
set test=
