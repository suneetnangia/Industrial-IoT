@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set current-path=%~dp0
rem // remove trailing slash
set current-path=%current-path:~0,-1%
shift

set PWSH=powershell

:check-az
set test=
for /f %%i in ('%PWSH% -Command "Get-Module -ListAvailable -Name Az.* | ForEach-Object Name"') do set test=%%i
if not "%test%" == "" goto :check-az-msi
echo Installing Az...
%PWSH% -Command "Install-Module -Name Az -AllowClobber -Scope CurrentUser"
goto :check-az-msi
:check-az-msi
echo Az installed.
set test=
for /f %%i in ('%PWSH% -Command "Get-Module -ListAvailable -Name Az.ManagedServiceIdentity | ForEach-Object Name"') do set test=%%i
if not "%test%" == "" goto :main
echo Installing Az.ManagedServiceIdentity...
%PWSH% -Command "Install-Module -Name Az.ManagedServiceIdentity -AllowClobber -Scope CurrentUser"
goto :main
:main
echo Az.ManagedServiceIdentity installed.
set test=
pushd %current-path%\deploy\scripts

%PWSH% -ExecutionPolicy Unrestricted ./deploy.ps1 %*
popd
