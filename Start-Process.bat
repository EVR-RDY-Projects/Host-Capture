@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Process\Start-HostProcess.ps1" %*
exit /b %ERRORLEVEL%
