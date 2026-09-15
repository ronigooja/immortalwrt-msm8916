@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================
rem UFI003 / MSM8916 First-Flash Tool
rem
rem Flash order follows the upstream x7780 first-flash script:
rem   detect device
rem   -> flash lk2nd to boot
rem   -> reboot to Fastboot
rem   -> backup fsc/fsg/modemst1/modemst2
rem   -> erase lk2nd/boot
rem   -> reboot bootloader
rem   -> flash GPT
rem   -> flash hyp/rpm/sbl1/tz
rem   -> restore fsc/fsg/modemst1/modemst2
rem   -> flash aboot/cdt
rem   -> erase boot/rootfs
rem   -> reboot to Fastboot
rem   -> flash boot.img/system.img
rem   -> reboot
rem
rem This version changes only script robustness:
rem   - ASCII-only
rem   - fixed working directory
rem   - uses packaged adb/fastboot from parent folder first
rem   - Fastboot is preferred over ADB
rem   - refuses multiple devices
rem   - checks required files before flashing
rem   - verifies calibration backups are non-empty
rem   - waits for Fastboot instead of blindly sleeping
rem   - stops immediately on critical command failure
rem
rem It does NOT add partition-layout guessing or alter flash order.
rem ============================================================

title UFI003 MSM8916 First Flash

pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Cannot enter script directory.
    echo Copy the firmware folder to a local Windows drive.
    pause
    exit /b 1
)

set "WORKDIR=%CD%"
set "BACKUPDIR=%WORKDIR%\fastboot_backup"
set "FASTBOOT="
set "ADB="
set "FASTBOOT_SERIAL="
set "ADB_SERIAL="
set "DESTRUCTIVE=0"

echo ============================================================
echo UFI003 / MSM8916 First-Flash Tool
echo ============================================================
echo.
echo Working directory:
echo   %WORKDIR%
echo.

rem ------------------------------------------------------------
rem Locate tools.
rem The release-package layout normally keeps adb.exe/fastboot.exe
rem one directory above the firstflash folder.
rem ------------------------------------------------------------

if exist "%WORKDIR%\..\fastboot.exe" set "FASTBOOT=%WORKDIR%\..\fastboot.exe"
if not defined FASTBOOT if exist "%WORKDIR%\fastboot.exe" set "FASTBOOT=%WORKDIR%\fastboot.exe"
if not defined FASTBOOT (
    for /f "delims=" %%I in ('where fastboot.exe 2^>nul') do (
        if not defined FASTBOOT set "FASTBOOT=%%I"
    )
)

if exist "%WORKDIR%\..\adb.exe" set "ADB=%WORKDIR%\..\adb.exe"
if not defined ADB if exist "%WORKDIR%\adb.exe" set "ADB=%WORKDIR%\adb.exe"
if not defined ADB (
    for /f "delims=" %%I in ('where adb.exe 2^>nul') do (
        if not defined ADB set "ADB=%%I"
    )
)

if not defined FASTBOOT (
    echo ERROR: fastboot.exe was not found.
    echo Expected first choice:
    echo   %WORKDIR%\..\fastboot.exe
    goto :fail
)

echo Fastboot:
echo   %FASTBOOT%
if defined ADB (
    echo ADB:
    echo   %ADB%
) else (
    echo ADB:
    echo   not found - Fastboot-only start is still supported
)
echo.

rem ------------------------------------------------------------
rem Required-file precheck.
rem ------------------------------------------------------------

echo [PRECHECK] Checking required firmware files...

call :require_file "lk2nd.img"
if errorlevel 1 goto :fail
call :require_file "gpt_both0.bin"
if errorlevel 1 goto :fail
call :require_file "hyp.mbn"
if errorlevel 1 goto :fail
call :require_file "rpm.mbn"
if errorlevel 1 goto :fail
call :require_file "sbl1.mbn"
if errorlevel 1 goto :fail
call :require_file "tz.mbn"
if errorlevel 1 goto :fail
call :require_file "aboot.bin"
if errorlevel 1 goto :fail
call :require_file "sbc_1.0_8016.bin"
if errorlevel 1 goto :fail
call :require_file "boot.img"
if errorlevel 1 goto :fail
call :require_file "system.img"
if errorlevel 1 goto :fail

if exist "%BACKUPDIR%" (
    echo.
    echo ERROR: Backup directory already exists:
    echo   %BACKUPDIR%
    echo.
    echo This script will not overwrite an earlier calibration backup.
    echo Rename or move that directory, then run this script again.
    goto :fail
)

echo Required files: OK
echo.

rem ------------------------------------------------------------
rem Stage 1 - Detect device.
rem Prefer Fastboot because a device with lk2nd already installed
rem should not be touched through some unrelated ADB connection.
rem ------------------------------------------------------------

:detect_start
echo [1/4] Detecting device...
echo.

call :detect_fastboot
if "%ERRORLEVEL%"=="0" (
    echo Fastboot device detected:
    echo   %FASTBOOT_SERIAL%
    goto :fastboot_ready
)
if "%ERRORLEVEL%"=="2" (
    echo ERROR: More than one Fastboot device is connected.
    echo Disconnect all unrelated Android/Fastboot devices.
    goto :fail
)

if defined ADB (
    call :detect_adb
    if "%ERRORLEVEL%"=="0" (
        echo Authorized ADB device detected:
        echo   %ADB_SERIAL%
        echo.
        echo Rebooting it into Bootloader mode...
        "%ADB%" -s "%ADB_SERIAL%" reboot bootloader
        if errorlevel 1 (
            echo ERROR: adb reboot bootloader failed.
            goto :fail
        )

        call :wait_fastboot 120
        if errorlevel 1 goto :fail
        goto :fastboot_ready
    )
    if "%ERRORLEVEL%"=="2" (
        echo ERROR: More than one authorized ADB device is connected.
        echo Disconnect all unrelated Android devices.
        goto :fail
    )
)

echo No usable Fastboot or authorized ADB device was detected.
echo.
choice /C RQ /N /M "Press R to retry or Q to quit: "
if errorlevel 2 goto :cancel
goto :detect_start

:fastboot_ready
echo.
echo Using Fastboot serial:
echo   %FASTBOOT_SERIAL%
echo.

rem ------------------------------------------------------------
rem Stage 2 - Install / refresh lk2nd.
rem Same flash sequence as upstream.
rem ------------------------------------------------------------

echo [2/4] Flashing lk2nd bootloader...
echo.

call :fb erase boot
if errorlevel 1 goto :fail

call :fb flash boot "%WORKDIR%\lk2nd.img"
if errorlevel 1 goto :fail

call :fb reboot
if errorlevel 1 goto :fail

echo.
echo Waiting for lk2nd Fastboot...
call :wait_fastboot 120
if errorlevel 1 goto :fail

echo Fastboot returned:
"%FASTBOOT%" -s "%FASTBOOT_SERIAL%" devices
echo.

rem ------------------------------------------------------------
rem Stage 3 - Backup calibration partitions.
rem Same partitions as upstream.
rem ------------------------------------------------------------

echo [3/4] Backing up modem/calibration partitions...
echo.

mkdir "%BACKUPDIR%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Could not create:
    echo   %BACKUPDIR%
    goto :fail
)

call :dump_partition fsc
if errorlevel 1 goto :fail

call :dump_partition fsg
if errorlevel 1 goto :fail

call :dump_partition modemst1
if errorlevel 1 goto :fail

call :dump_partition modemst2
if errorlevel 1 goto :fail

call :verify_backup "%BACKUPDIR%\fsc.bin"
if errorlevel 1 goto :fail
call :verify_backup "%BACKUPDIR%\fsg.bin"
if errorlevel 1 goto :fail
call :verify_backup "%BACKUPDIR%\modemst1.bin"
if errorlevel 1 goto :fail
call :verify_backup "%BACKUPDIR%\modemst2.bin"
if errorlevel 1 goto :fail

echo.
echo Calibration backup completed successfully.
echo.
for %%F in (
    "%BACKUPDIR%\fsc.bin"
    "%BACKUPDIR%\fsg.bin"
    "%BACKUPDIR%\modemst1.bin"
    "%BACKUPDIR%\modemst2.bin"
) do echo   %%~nxF  %%~zF bytes

echo.
echo ============================================================
echo WARNING: THE NEXT STAGE REPARTITIONS THE DEVICE
echo ============================================================
echo.
echo From this point onward the script follows the upstream
echo destructive flash sequence.
echo.
echo Confirm that your separate full EDL backup is safe.
echo.
set "CONFIRM="
set /p "CONFIRM=Type FLASH exactly to continue: "
if /I not "%CONFIRM%"=="FLASH" goto :cancel

set "DESTRUCTIVE=1"

rem ------------------------------------------------------------
rem Prepare for GPT replacement.
rem Upstream runs erase lk2nd even though it may not exist on the
rem original GPT. That single command is allowed to fail.
rem ------------------------------------------------------------

echo.
echo Preparing device for GPT replacement...
echo.

echo [FASTBOOT] erase lk2nd
"%FASTBOOT%" -s "%FASTBOOT_SERIAL%" erase lk2nd
echo Note: failure of erase lk2nd is allowed on the original layout.
echo.

call :fb erase boot
if errorlevel 1 goto :fail

call :fb reboot bootloader
if errorlevel 1 goto :fail

echo.
echo Waiting for Bootloader Fastboot...
call :wait_fastboot 120
if errorlevel 1 goto :fail

rem ------------------------------------------------------------
rem GPT + low-level firmware.
rem Order intentionally matches upstream.
rem ------------------------------------------------------------

echo.
echo Flashing GPT...
call :fb flash partition "%WORKDIR%\gpt_both0.bin"
if errorlevel 1 goto :fail

echo.
echo Flashing low-level firmware...

call :fb flash hyp "%WORKDIR%\hyp.mbn"
if errorlevel 1 goto :fail

call :fb flash rpm "%WORKDIR%\rpm.mbn"
if errorlevel 1 goto :fail

call :fb flash sbl1 "%WORKDIR%\sbl1.mbn"
if errorlevel 1 goto :fail

call :fb flash tz "%WORKDIR%\tz.mbn"
if errorlevel 1 goto :fail

rem ------------------------------------------------------------
rem Restore calibration partitions immediately after GPT change.
rem ------------------------------------------------------------

echo.
echo Restoring modem/calibration partitions...

call :fb flash fsc "%BACKUPDIR%\fsc.bin"
if errorlevel 1 goto :fail

call :fb flash fsg "%BACKUPDIR%\fsg.bin"
if errorlevel 1 goto :fail

call :fb flash modemst1 "%BACKUPDIR%\modemst1.bin"
if errorlevel 1 goto :fail

call :fb flash modemst2 "%BACKUPDIR%\modemst2.bin"
if errorlevel 1 goto :fail

call :fb flash aboot "%WORKDIR%\aboot.bin"
if errorlevel 1 goto :fail

call :fb flash cdt "%WORKDIR%\sbc_1.0_8016.bin"
if errorlevel 1 goto :fail

call :fb erase boot
if errorlevel 1 goto :fail

call :fb erase rootfs
if errorlevel 1 goto :fail

echo.
echo Low-level firmware flashing completed.
echo Rebooting...
call :fb reboot
if errorlevel 1 goto :fail

echo.
echo Waiting for Fastboot after low-level flash...
call :wait_fastboot 120
if errorlevel 1 goto :fail

rem ------------------------------------------------------------
rem Stage 4 - Flash OS images.
rem Same commands and target partitions as upstream.
rem ------------------------------------------------------------

echo.
echo [4/4] Flashing system images...
echo.

call :fb flash boot "%WORKDIR%\boot.img"
if errorlevel 1 goto :fail

call :fb -S 200m flash rootfs "%WORKDIR%\system.img"
if errorlevel 1 goto :fail

echo.
echo System image flashing completed.
echo Rebooting device...
call :fb reboot
if errorlevel 1 goto :fail

echo.
echo ============================================================
echo FLASH COMPLETED SUCCESSFULLY
echo ============================================================
echo.
echo Keep these backups:
echo   - your full EDL backup
echo   - %BACKUPDIR%
echo.
goto :success


rem ============================================================
rem Helpers
rem ============================================================

:require_file
if not exist "%WORKDIR%\%~1" (
    echo ERROR: Missing required file:
    echo   %~1
    exit /b 1
)
for %%F in ("%WORKDIR%\%~1") do (
    if %%~zF LEQ 0 (
        echo ERROR: Required file is empty:
        echo   %~1
        exit /b 1
    )
)
exit /b 0


:detect_fastboot
set "FASTBOOT_SERIAL="
set "FB_COUNT=0"

for /f "tokens=1,2" %%A in ('"%FASTBOOT%" devices 2^>nul') do (
    if /I "%%B"=="fastboot" (
        set /a FB_COUNT+=1
        set "FASTBOOT_SERIAL=%%A"
    )
)

if "%FB_COUNT%"=="1" exit /b 0
if "%FB_COUNT%"=="0" exit /b 1
set "FASTBOOT_SERIAL="
exit /b 2


:detect_adb
set "ADB_SERIAL="
set "ADB_COUNT=0"

for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices 2^>nul') do (
    if /I "%%B"=="device" (
        set /a ADB_COUNT+=1
        set "ADB_SERIAL=%%A"
    )
)

if "%ADB_COUNT%"=="1" exit /b 0
if "%ADB_COUNT%"=="0" exit /b 1
set "ADB_SERIAL="
exit /b 2


:wait_fastboot
set "WAIT_SECONDS=%~1"
if not defined WAIT_SECONDS set "WAIT_SECONDS=120"

echo Waiting up to %WAIT_SECONDS% seconds...

for /L %%I in (1,1,%WAIT_SECONDS%) do (
    call :detect_fastboot
    if not errorlevel 1 exit /b 0
    timeout /T 1 /NOBREAK >nul
)

echo ERROR: Fastboot device did not return.
echo.
echo Check Device Manager and USB assignment.
exit /b 1


:dump_partition
set "PART=%~1"

echo.
echo Backing up %PART%...

call :fb oem dump %PART%
if errorlevel 1 exit /b 1

call :fb get_staged "%BACKUPDIR%\%PART%.bin"
if errorlevel 1 exit /b 1

exit /b 0


:verify_backup
if not exist "%~1" (
    echo ERROR: Backup file was not created:
    echo   %~1
    exit /b 1
)
for %%F in ("%~1") do (
    if %%~zF LEQ 0 (
        echo ERROR: Backup file is empty:
        echo   %~1
        exit /b 1
    )
)
exit /b 0


:fb
echo.
echo [FASTBOOT] %*
"%FASTBOOT%" -s "%FASTBOOT_SERIAL%" %*
if errorlevel 1 (
    echo.
    echo ERROR: Fastboot command failed:
    echo   %*
    exit /b 1
)
exit /b 0


:fail
echo.
echo ============================================================
echo FLASH STOPPED
echo ============================================================
echo.
if "%DESTRUCTIVE%"=="1" (
    echo The failure occurred AFTER destructive flashing began.
    echo Do not run random recovery commands.
    echo Keep the exact failed command/output.
) else (
    echo GPT repartitioning was not started by this script.
)
echo.
pause
popd
endlocal
exit /b 1


:cancel
echo.
echo Operation cancelled.
echo.
pause
popd
endlocal
exit /b 0


:success
echo.
pause
popd
endlocal
exit /b 0
