@echo off
REM ===========================================================================
REM  RUN_IMPORT.bat - run this ON THE NEW SERVER (VM1535)
REM
REM  Just double-click it. It loads the exported files into a staging area.
REM
REM  It does NOT touch your real tables. Everything lands in a separate
REM  schema called stg, and nothing moves into the live tables until you
REM  run 05_generate_merge_sql.sql and ask it to.
REM ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

echo.
echo  ==========================================================
echo   LOAD THE EXPORTED FILES INTO STAGING ON THE NEW SERVER
echo  ==========================================================
echo.
echo  This does not change any of your real tables.
echo.

set "SERVER="
set /p SERVER=SQL server name [VM1535]:
if "!SERVER!"=="" set "SERVER=VM1535"

set "DBNAME="
set /p DBNAME=Database name [DatingTid]:
if "!DBNAME!"=="" set "DBNAME=DatingTid"

echo.
echo  Leave the login blank to connect with your Windows account.
set "SQLUSER="
set /p SQLUSER=SQL login (blank = Windows login):

set "SQLPASS="
if not "!SQLUSER!"=="" set /p SQLPASS=Password for !SQLUSER!:

set "INDIR="
set /p INDIR=Folder with the exported files [D:\delta\!DBNAME!]:
if "!INDIR!"=="" set "INDIR=D:\delta\!DBNAME!"

echo.
echo  ----------------------------------------------------------
echo   Server   : !SERVER!
echo   Database : !DBNAME!
echo   Login    : !SQLUSER! (blank means Windows login)
echo   Input    : !INDIR!
echo  ----------------------------------------------------------
echo.
pause

if "!SQLUSER!"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp004_import_to_staging.ps1" -Server "!SERVER!" -Database "!DBNAME!" -InDir "!INDIR!" -TrustServerCert
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp004_import_to_staging.ps1" -Server "!SERVER!" -Database "!DBNAME!" -User "!SQLUSER!" -Password "!SQLPASS!" -InDir "!INDIR!" -TrustServerCert
)

echo.
if errorlevel 1 (
    echo  *** Something went wrong. Read the messages above, and look at
    echo  *** import_log.txt in !INDIR! - it records everything.
) else (
    echo  Done - and your real tables have not been touched yet.
    echo.
    echo  Next: open 05_generate_merge_sql.sql in SQL Server Management
    echo  Studio on this server, run it, and READ what it prints before
    echo  letting it do anything.
)
echo.
pause
endlocal
