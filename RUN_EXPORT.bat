@echo off
REM ===========================================================================
REM  RUN_EXPORT.bat - run this ON THE OLD SERVER (VM0810)
REM
REM  Just double-click it. It asks a few questions and does the rest.
REM
REM  This is the safe way to run 03_export_delta.ps1. Do NOT paste the .ps1
REM  file into SQL Server Management Studio - that is PowerShell, not SQL,
REM  and SSMS will only give you a screen full of syntax errors.
REM
REM  Nothing here writes to the old database. It only reads.
REM ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

echo.
echo  ==========================================================
echo   EXPORT THE GAP FROM THE OLD SERVER
echo  ==========================================================
echo.

set "SERVER="
set /p SERVER=SQL server name [VM0810]:
if "!SERVER!"=="" set "SERVER=VM0810"

set "DBNAME="
set /p DBNAME=Database name [DatingTid]:
if "!DBNAME!"=="" set "DBNAME=DatingTid"

echo.
echo  Leave the login blank to connect with your Windows account.
set "SQLUSER="
set /p SQLUSER=SQL login (blank = Windows login):

set "SQLPASS="
if not "!SQLUSER!"=="" set /p SQLPASS=Password for !SQLUSER!:

set "OUTDIR="
set /p OUTDIR=Where to put the files [D:\delta\!DBNAME!]:
if "!OUTDIR!"=="" set "OUTDIR=D:\delta\!DBNAME!"

set "CFG="
set /p CFG=Config file [tables.csv]:
if "!CFG!"=="" set "CFG=tables.csv"

echo.
echo  ----------------------------------------------------------
echo   Server   : !SERVER!
echo   Database : !DBNAME!
echo   Login    : !SQLUSER! (blank means Windows login)
echo   Config   : !CFG!
echo   Output   : !OUTDIR!
echo  ----------------------------------------------------------
echo.
pause

if "!SQLUSER!"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp003_export_delta.ps1" -Server "!SERVER!" -Database "!DBNAME!" -ConfigFile "!CFG!" -OutDir "!OUTDIR!" -TrustServerCert
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp003_export_delta.ps1" -Server "!SERVER!" -Database "!DBNAME!" -User "!SQLUSER!" -Password "!SQLPASS!" -ConfigFile "!CFG!" -OutDir "!OUTDIR!" -TrustServerCert
)

echo.
if errorlevel 1 (
    echo  *** Something went wrong. Read the messages above, and look at
    echo  *** export_log.txt in !OUTDIR! - it records everything.
) else (
    echo  Done. Now copy the whole folder !OUTDIR! to the new server
    echo  and run RUN_IMPORT.bat over there.
)
echo.
pause
endlocal
