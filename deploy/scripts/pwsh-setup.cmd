@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set current-path=%~dp0
rem // remove trailing slash
set current-path=%current-path:~0,-1%
shift

if "%PWSH%" == "" set PWSH=powershell
%PWSH% -ExecutionPolicy Unrestricted %current-path%/pwsh-setup.ps1 -Scope CurrentUser
