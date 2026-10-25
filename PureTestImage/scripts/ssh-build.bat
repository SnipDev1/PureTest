@echo off
rem ---------------------------------------------------------------------------
rem  ssh-build.bat - builds PureTestImage entirely from Windows, over SSH.
rem
rem  Works from ANY folder (it cd's to the repo root itself).
rem  Requirements:
rem    - SSH access to your Ubuntu Server (key or password).
rem    - First run will configure passwordless sudo if needed (prompts once).
rem
rem  Configuration is loaded from scripts\ssh-build.env if present.
rem  Otherwise, default/fallback values below are used:
rem ---------------------------------------------------------------------------
cd /d "%~dp0.."
set "REMOTE_USER=ubuntu"
set "HOST=192.168.1.100"
set "PORT=22"
set "REMOTE_DIR=~/PureTestImage"
set "USE_CACHE=1"

if exist "%~dp0ssh-build.env" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%~dp0ssh-build.env") do (
        set "%%a=%%b"
    )
)

if "%HOST%"=="192.168.1.100" (
    echo.
    echo [!] WARNING: Default server host '192.168.1.100' detected.
    echo     Please copy scripts\ssh-build.env.example to scripts\ssh-build.env
    echo     and specify your actual server details before running.
    echo.
)

set "SSH=ssh -p %PORT% %REMOTE_USER%@%HOST%"
rem ---------------------------------------------------------------------------

echo.
echo === PureTestImage: remote build over SSH ===
echo   %REMOTE_USER%@%HOST%:%PORT%  dir=%REMOTE_DIR%
echo.

rem ---- Step 0a: Check SSH connectivity ----
echo [0] Checking SSH connectivity ...
%SSH% -o BatchMode=yes -o ConnectTimeout=10 "echo ok" >nul 2>&1
if errorlevel 1 (
    echo ERROR: cannot connect to %REMOTE_USER%@%HOST%:%PORT%
    echo   Check SSH key/password, scripts\ssh-build.env settings, and server reachability.
    pause
    exit /b 1
)
echo   SSH connection OK.

rem ---- Step 0b: Ensure passwordless sudo ----
echo     Checking sudo access ...
%SSH% -o BatchMode=yes "sudo -n true" >nul 2>&1
if not errorlevel 1 goto sudo_ok

echo.
echo   Passwordless sudo is NOT configured on the server.
echo   Setting it up now -- you will be asked for the sudo password ONCE.
echo.
scp -P %PORT% scripts\setup-sudo.sh "%REMOTE_USER%@%HOST%:/tmp/setup-sudo.sh"
ssh -tt -p %PORT% %REMOTE_USER%@%HOST% "bash /tmp/setup-sudo.sh; rm -f /tmp/setup-sudo.sh"
if errorlevel 1 (
    echo ERROR: could not configure passwordless sudo.
    pause
    exit /b 1
)
rem Verify
%SSH% -o BatchMode=yes "sudo -n true" >nul 2>&1
if errorlevel 1 (
    echo ERROR: passwordless sudo still not working after setup.
    pause
    exit /b 1
)
echo   Passwordless sudo configured OK.

:sudo_ok
echo   sudo access OK.

rem ---- Step 0c: Clean leftovers from aborted builds safely ----
%SSH% "sudo bash -c 'for m in $(findmnt -rn -o TARGET 2>/dev/null | grep \"/tmp/tmp\.\"); do umount -l \"$m\" 2>/dev/null; done'; true"


rem ---- Step 1: Sync sources ----
echo.
echo [1/3] Syncing sources to server ...
%SSH% "mkdir -p %REMOTE_DIR% && rm -rf %REMOTE_DIR%/board %REMOTE_DIR%/scripts"
scp -P %PORT% -r scripts board tests README.md .gitignore "%REMOTE_USER%@%HOST%:%REMOTE_DIR%/"
if errorlevel 1 (
    echo ERROR: scp upload failed.
    exit /b 1
)

rem ---- Step 2: Build ----
echo.
echo [2/3] Running build.sh on server (USE_CACHE=%USE_CACHE%) ...
%SSH% "cd %REMOTE_DIR% && sudo USE_CACHE=%USE_CACHE% bash scripts/build.sh"
if errorlevel 1 (
    echo ERROR: remote build failed.
    exit /b 1
)

rem ---- Step 3: Download compressed archive ----
echo.
echo [3/3] Downloading compressed puretest.img.tar.gz ...
mkdir output 2>nul
set "REMOTE_ARCHIVE=%REMOTE_USER%@%HOST%:%REMOTE_DIR%/output/puretest.img.tar.gz"
set "LOCAL_ARCHIVE=output\puretest.img.tar.gz"
set /a TRY=0
:retry_download
set /a TRY+=1
scp -P %PORT% -o ConnectTimeout=30 "%REMOTE_ARCHIVE%" "%LOCAL_ARCHIVE%"
if not errorlevel 1 goto download_ok
echo   attempt %TRY% failed - retrying ...
timeout /t 5 /nobreak >nul
if %TRY% lss 6 goto retry_download
echo ERROR: could not download %REMOTE_ARCHIVE%
exit /b 1
:download_ok

echo.
echo Extracting puretest.img from archive ...
tar -xzf "%LOCAL_ARCHIVE%" -C output
if errorlevel 1 (
    echo NOTE: Auto-extraction with tar failed.
    echo       You can open output\puretest.img.tar.gz directly in Rufus or 7-Zip.
) else (
    echo Extraction OK: output\puretest.img
)

echo.
echo ====================================================
echo  DONE!
echo  Raw Image : output\puretest.img
echo  Archive   : output\puretest.img.tar.gz
echo.
echo  Write it to a USB stick with Rufus in "DD image"
echo  mode, or with Balena Etcher. Then put C++ tests in
echo  the DATADISK partition (see README.txt on it).
echo ====================================================
