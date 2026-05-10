@ECHO OFF
title NoKape Legacy Host Capture
setlocal enabledelayedexpansion
cd /D %~dp0\..

NET SESSION >nul 2>&1
IF NOT %ERRORLEVEL% EQU 0 (
    echo ################ ERROR: ADMIN PRIVILEGES REQUIRED! #################
    echo This script must be run with Admin privileges.
    pause
    EXIT /B 1
)

set home=%CD%\
set capture=%home%Capture
set binaries=%home%Tools\binaries
set collection=%home%Collection
set noprompt=no
set planonly=no
set domem=ask
set doart=ask
set skipopnotes=no
call :parseargs %*
set robocopy=robocopy.exe
if exist "%binaries%\robocopy.exe" set robocopy=%binaries%\robocopy.exe
if exist "%binaries%\robocopy.exe.exe" set robocopy=%binaries%\robocopy.exe.exe
if not exist "%collection%" mkdir "%collection%"

set m=%DATE:~4,2%
set d=%DATE:~7,2%
set y=%DATE:~10,4%
set hh=%TIME:~0,2%
set mm=%TIME:~3,2%
if "%hh:~0,1%"==" " set hh=0%hh:~1,1%
set timestamp=%y%.%m%.%d%.%hh%.%mm%.
set outpath=%collection%\%computername%--%timestamp%--LEGACY
mkdir "%outpath%" >nul 2>&1
set logfile=%outpath%\%computername%-%timestamp%.log
echo %DATE% %TIME%: Logging: "%logfile%" > "%logfile%"
echo %DATE% %TIME%: Running as %USERNAME% on %computername%... >> "%logfile%"
call :manifest_start

if /I "%planonly%"=="yes" (
    echo Output: %outpath%
    echo Memory: %domem%
    echo Artifact: %doart%
    echo EffectiveMode: Legacy
    echo KapeUsed: False
    call :manifest_finish
    exit /b 0
)

echo.
echo *************************************************************************
echo                           MEMORY COLLECTION
echo *************************************************************************
if /I "%domem%"=="ask" if /I "%noprompt%"=="yes" set domem=n
if /I "%domem%"=="ask" set /p domem=Would you like to conduct a memory capture? (y/n): 
if /I "%domem%"=="y" call :memcap
if /I "%domem%"=="yes" call :memcap

echo.
echo *************************************************************************
echo                           ARTIFACT COLLECTION
echo *************************************************************************
if /I "%doart%"=="ask" if /I "%noprompt%"=="yes" set doart=y
if /I "%doart%"=="ask" set /p doart=Would you like to conduct an artifact capture? (y/n): 
if /I "%doart%"=="y" call :legacy
if /I "%doart%"=="yes" call :legacy

if /I not "%skipopnotes%"=="yes" call :opnotes
call :manifest_finish
echo.
echo Output: %outpath%
if /I not "%noprompt%"=="yes" pause
exit /b 0

:parseargs
if "%~1"=="" exit /b 0
if /I "%~1"=="-NoPrompt" set noprompt=yes
if /I "%~1"=="-PlanOnly" set planonly=yes
if /I "%~1"=="-SkipOpNotes" set skipopnotes=yes
if /I "%~1"=="-Memory" (
    if /I "%~2"=="No" set domem=n
    if /I "%~2"=="Yes" set domem=y
    shift
)
if /I "%~1"=="-Artifact" (
    if /I "%~2"=="No" set doart=n
    if /I "%~2"=="Yes" set doart=y
    shift
)
shift
goto parseargs

:memcap
echo %DATE% %TIME%: Memory Capture in progress; please wait... >> "%logfile%"
if "%PROCESSOR_ARCHITECTURE%"=="x86" if exist "%binaries%\DumpIt.exe" "%binaries%\DumpIt.exe" /Q /N /J /R /O "%outpath%\%computername%--%timestamp%.zdmp" >nul 2>&1
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" if exist "%binaries%\DumpIt64.exe" "%binaries%\DumpIt64.exe" /Q /N /J /R /O "%outpath%\%computername%--%timestamp%.zdmp" >nul 2>&1
echo %DATE% %TIME%: MemCap Complete! >> "%logfile%"
exit /b 0

:manifest_start
set manifest=%outpath%\capture-manifest.json
echo {>"%manifest%"
echo   "Tool": "NoKapeHostCaptureLegacy",>>"%manifest%"
echo   "Version": "0.2.0",>>"%manifest%"
echo   "ComputerName": "%computername%",>>"%manifest%"
echo   "User": "%USERNAME%",>>"%manifest%"
echo   "EffectiveMode": "Legacy",>>"%manifest%"
echo   "KapeUsed": false,>>"%manifest%"
echo   "EzToolsUsed": false,>>"%manifest%"
echo   "StartedLocal": "%DATE% %TIME%",>>"%manifest%"
echo   "Output": "%outpath:\=\\%",>>"%manifest%"
echo   "Note": "XP-safe batch manifest. Detailed command/file activity is recorded in the root log.",>>"%manifest%"
exit /b 0

:manifest_finish
echo   "FinishedLocal": "%DATE% %TIME%">>"%manifest%"
echo }>>"%manifest%"
exit /b 0

:legacy
if "%PROCESSOR_ARCHITECTURE%"=="x86" set rawcopy=%binaries%\rawcopy.exe
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set rawcopy=%binaries%\rawcopy64.exe
if "%PROCESSOR_ARCHITECTURE%"=="x86" set extusn=%binaries%\extractusnjournal.exe
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set extusn=%binaries%\extranctusnjournal64.exe

for /f "usebackq tokens=5,6" %%a in (`systeminfo ^| find "OS Name"`) do (
    set first=%%a
    set second=%%b
)
set build=%first% %second%
echo %build% | findstr /i /c:"XP" >nul && set style=old
echo %build% | findstr /i /c:"2003" >nul && set style=old

set regsavepath=%outpath%\Registry
set ntfssavepath=%outpath%\File_System
set pfsavepath=%outpath%\Prefetch
set txtsavepath=%outpath%\TXT
set shimsavepath=%outpath%\Shim
if "%style%"=="old" (set evtsavepath=%outpath%\Evt) else (set evtsavepath=%outpath%\Evtx)
for %%p in ("%regsavepath%" "%ntfssavepath%" "%pfsavepath%" "%txtsavepath%" "%shimsavepath%" "%evtsavepath%") do mkdir %%p >nul 2>&1

if "%style%"=="old" (
    set commands=%capture%\XP_COMMANDS.txt
    for /f "usebackq" %%a in (`dir "C:\Documents and Settings" /B/O/A:D 2^>nul`) do (
        if exist "C:\Documents and Settings\%%a\Recent" (
            mkdir "%outpath%\LNK\%%a" >nul 2>&1
            "%robocopy%" "C:\Documents and Settings\%%a\Recent" "%outpath%\LNK\%%a" /E /COPYALL >nul 2>&1
        )
    )
) else (
    set commands=%capture%\MODERN_COMMANDS.txt
    for /f "usebackq" %%a in (`dir "C:\Users" /B/O/A:D 2^>nul`) do (
        if exist "C:\Users\%%a\AppData\Roaming\Microsoft\Windows\Recent" (
            mkdir "%outpath%\LNK\%%a" >nul 2>&1
            "%robocopy%" "C:\Users\%%a\AppData\Roaming\Microsoft\Windows\Recent" "%outpath%\LNK\%%a" /E /COPYALL >nul 2>&1
        )
    )
)

tree C:\ /F /A > "%ntfssavepath%\%computername%-dirwalk.txt" 2>nul

for /f "usebackq tokens=1,*" %%a in (`type "%commands%" ^| findstr /v ^;`) do (
    echo !DATE! !TIME!: %%b ^> "%txtsavepath%\%%a.txt" >> "%logfile%"
    %SYSTEMROOT%\system32\cmd.exe /v:on /s /c %%b > "%txtsavepath%\%%a.txt" 2>nul
)

if "%style%"=="old" (
    if exist "%SYSTEMROOT%\System32\config\AppEvent.evt" if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\AppEvent.evt /OutputPath:"%evtsavepath%" >nul 2>&1
    if exist "%SYSTEMROOT%\System32\config\SecEvent.evt" if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\SecEvent.evt /OutputPath:"%evtsavepath%" >nul 2>&1
    if exist "%SYSTEMROOT%\System32\config\SysEvent.evt" if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\SysEvent.evt /OutputPath:"%evtsavepath%" >nul 2>&1
) else (
    for %%e in (Application Security System "Windows PowerShell") do wevtutil.exe epl %%e "%evtsavepath%\%%~e.evtx" /ow:true >nul 2>&1
)

for %%h in (SAM SECURITY SOFTWARE SYSTEM) do (
    if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\%%h /OutputPath:"%regsavepath%" >nul 2>&1
    if exist "%SYSTEMROOT%\System32\config\%%h.log" if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\%%h.log /OutputPath:"%regsavepath%" >nul 2>&1
    if exist "%SYSTEMROOT%\System32\config\%%h.log1" if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\%%h.log1 /OutputPath:"%regsavepath%" >nul 2>&1
    if exist "%SYSTEMROOT%\System32\config\%%h.log2" if exist "%rawcopy%" "%rawcopy%" /FileNamePath:%SYSTEMROOT%\System32\config\%%h.log2 /OutputPath:"%regsavepath%" >nul 2>&1
)

if "%style%"=="old" (
    for /f "usebackq" %%a in (`dir "C:\Documents and Settings" /B/O/A:D 2^>nul`) do call :copyuserxp "%%a"
    "%robocopy%" "%WINDIR%" "%regsavepath%" setupapi* /COPYALL >nul 2>&1
) else (
    for /f "usebackq" %%a in (`dir "C:\Users" /B/O/A:D 2^>nul`) do call :copyusermodern "%%a"
    "%robocopy%" "%WINDIR%\Inf" "%regsavepath%" setupapi.dev.log /COPYALL >nul 2>&1
)

"%robocopy%" "%SYSTEMROOT%\AppPatch" "%shimsavepath%" sysmain.sdb /COPYALL >nul 2>&1
"%robocopy%" "%SYSTEMROOT%\Prefetch" "%pfsavepath%" /S /E >nul 2>&1
exit /b 0

:copyuserxp
set user=%~1
mkdir "%regsavepath%\%user%" >nul 2>&1
if exist "%rawcopy%" "%rawcopy%" /FileNamePath:"C:\Documents and Settings\%user%\NTUSER.DAT" /OutputPath:"%regsavepath%\%user%" /OutputName:NTUSER.dat >nul 2>&1
if exist "%rawcopy%" "%rawcopy%" /FileNamePath:"C:\Documents and Settings\%user%\Local Settings\Application Data\Microsoft\Windows\USRCLASS.dat" /OutputPath:"%regsavepath%\%user%" /OutputName:USRCLASS.dat >nul 2>&1
exit /b 0

:copyusermodern
set user=%~1
mkdir "%regsavepath%\%user%" >nul 2>&1
if exist "%rawcopy%" "%rawcopy%" /FileNamePath:"C:\Users\%user%\NTUSER.DAT" /OutputPath:"%regsavepath%\%user%" /OutputName:NTUSER.dat >nul 2>&1
if exist "%rawcopy%" "%rawcopy%" /FileNamePath:"C:\Users\%user%\AppData\Local\Microsoft\Windows\USRCLASS.dat" /OutputPath:"%regsavepath%\%user%" /OutputName:USRCLASS.dat >nul 2>&1
exit /b 0

:opnotes
if not exist "%collection%\Opnotes.csv" echo Date,Hostname,IP/Mac,OS,Build,Building,Location,Purpose,Start_Time,Finish_Time,Drive,Analyst,Successful?,Notes>"%collection%\Opnotes.csv"
set /p opdate=Today's Date (eg. 01Jan2020): 
set /p start=Enter Collection Start Time (REAL time; eg. 2130): 
set /p finish=Enter Collection Finish Time (REAL time; eg. 2200): 
set /p building=Enter Building and Room Number: 
set /p location=Enter Physical Location of system: 
set /p purpose=Enter System Purpose: 
set /p harddrive=Enter Collection Hard Drive: 
set /p analyst=Enter Analyst Name: 
set /p success=Was Collection Successful? (y/n): 
set /p notes=Enter other notes: 
echo %opdate%,%computername%, ,%OS%,%build%,%building%,%location%,%purpose%,%start%,%finish%,%harddrive%,%analyst%,%success%,%notes%>>"%collection%\Opnotes.csv"
exit /b 0
