@REM Copyright (c) Microsoft. All rights reserved.
@REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

@setlocal EnableExtensions EnableDelayedExpansion
@echo off

set PWSH=powershell
set current-path=%~dp0
rem // remove trailing slash
set current-path=%current-path:~0,-1%
shift
pushd %current-path%
rem // check and if needed install powershell and required modules
call pwsh-setup.cmd
%PWSH% -ExecutionPolicy Unrestricted ./graph-register.ps1 %*
popd
