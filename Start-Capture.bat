@echo off
setlocal
cd /d "%~dp0"
ver | find "XP" >nul
if %ERRORLEVEL% EQU 0 goto legacy
ver | find "5.2" >nul
if %ERRORLEVEL% EQU 0 goto legacy
where powershell.exe >nul 2>&1
if %ERRORLEVEL% NEQ 0 goto legacy
call :checkdotnet45
if "%dotnet45%"=="no" goto legacy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Capture\Start-HostCapture.ps1" %*
exit /b %ERRORLEVEL%
:legacy
call "%~dp0Capture\Start-HostCaptureLegacy.bat" %*
exit /b %ERRORLEVEL%

:checkdotnet45
set dotnet45=no
set release=
for /f "tokens=3" %%r in ('reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release 2^>nul ^| find "Release"') do set release=%%r
if "%release%"=="" exit /b 0
if %release% GEQ 378389 set dotnet45=yes
exit /b 0
