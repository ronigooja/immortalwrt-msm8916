@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================
rem UFI003 / MSM8916 OpenWrt Upgrade Tool
rem
rem Flash scope follows the upstream "one-click upgrade patch":
rem   adb reboot bootloader (when starting from ADB)
rem   -> erase boot
rem   -> flash boot boot.img
rem   -> erase rootfs
rem   -> fastboot -S 200m flash rootfs system.img
rem   -> reboot
rem
rem This script DOES NOT touch:
rem   GPT / sbl1 / rpm / tz / hyp / aboot / cdt
rem   fsc / fsg / modemst1 / modemst2
rem
rem Robustness changes only:
rem   - ASCII-only / CRLF
rem   - fixed working directory
rem   - finds adb.exe / fastboot.exe in current or parent folder
rem   - prefers an existing Fastboot device over ADB
rem   - refuses multiple devices
rem   - verifies boot.img and system.img before erase
rem   - waits for real Fastboot connectivity
rem   - stops on any critical Fastboot failure
rem ============================================================

title UFI003 OpenWrt Upgrade

pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Cannot enter the script directory.
    pause
    exit /b 1
)

set "WORKDIR=%CD%"
set "FASTBOOT="
set "ADB="
set "FASTBOOT_SERIAL="
set "ADB_SERIAL="

echo ============================================================
echo UFI003 / MSM8916 OpenWrt Upgrade Tool
echo ============================================================
echo.
echo Working directory:
echo   %WORKDIR%
echo.

rem ------------------------------------------------------------
rem Locate fastboot.exe / adb.exe.
rem Upgrade packages usually keep the tools next to this BAT.
rem The parent-folder fallback also supports your firstflash layout.
rem ------------------------------------------------------------

if exist "%WORKDIR%\fastboot.exe" set "FASTBOOT=%WORKDIR%\fastboot.exe"
if not defined FASTBOOT if exist "%WORKDIR%\..\fastboot.exe" set "FASTBOOT=%WORKDIR%\..\fastboot.exe"
if not defined FASTBOOT (
    for /f "delims=" %%I in ('where fastboot.exe 2^>nul') do (
        if not defined FASTBOOT set "FASTBOOT=%%I"
    )
)

if exist "%WORKDIR%\adb.exe" set "ADB=%WORKDIR%\adb.exe"
if not defined ADB if exist "%WORKDIR%\..\adb.exe" set "ADB=%WORKDIR%\..\adb.exe"
if not defined ADB (
    for /f "delims=" %%I in ('where adb.exe 2^>nul') do (
        if not defined ADB set "ADB=%%I"
    )
)

if not defined FASTBOOT (
    echo ERROR: fastboot.exe was not found.
    goto :fail
)

echo Fastboot:
echo   %FASTBOOT%
if defined ADB (
    echo ADB:
    echo   %ADB%
) else (
    echo ADB:
    echo   not found - starting from Fastboot is still supported
)
echo.

rem ------------------------------------------------------------
rem Firmware precheck.
rem ------------------------------------------------------------

call :require_file "boot.img"
if errorlevel 1 goto :fail

call :require_file "system.img"
if errorlevel 1 goto :fail

echo Firmware files:
for %%F in ("%WORKDIR%\boot.img" "%WORKDIR%\system.img") do (
    echo   %%~nxF  %%~zF bytes
)
echo.

rem ------------------------------------------------------------
rem Detect device.
rem Prefer Fastboot if the device is already there.
rem ------------------------------------------------------------

:detect_device
echo [1/3] Detecting device...
echo.

call :detect_fastboot
if "%ERRORLEVEL%"=="0" (
    echo Fastboot device detected:
    echo   %FASTBOOT_SERIAL%
    goto :fastboot_ready
)
if "%ERRORLEVEL%"=="2" (
    echo ERROR: More than one Fastboot device is connected.
    echo Disconnect unrelated Android/Fastboot devices.
    goto :fail
)

if defined ADB (
    call :detect_adb
    if "%ERRORLEVEL%"=="0" (
        echo Authorized ADB device detected:
        echo   %ADB_SERIAL%
        echo.
        echo Rebooting to bootloader...
        "%ADB%" -s "%ADB_SERIAL%" reboot bootloader
        if errorlevel 1 (
            echo ERROR: adb reboot bootloader failed.
            goto :fail
        )

        call :wait_fastboot
        if errorlevel 1 goto :fail
        goto :fastboot_ready
    )
    if "%ERRORLEVEL%"=="2" (
        echo ERROR: More than one authorized ADB device is connected.
        echo Disconnect unrelated Android devices.
        goto :fail
    )
)

echo No usable Fastboot or authorized ADB device was detected.
echo.
choice /C RQ /N /M "Press R to retry or Q to quit: "
if errorlevel 2 goto :cancel
goto :detect_device

:fastboot_ready
echo.
echo Fastboot is ready:
echo   %FASTBOOT_SERIAL%
echo.

rem Verify that commands can actually reach the device.
echo Checking Fastboot command channel...
"%FASTBOOT%" -s "%FASTBOOT_SERIAL%" getvar version >nul 2>&1
if errorlevel 1 (
    echo ERROR: The device is listed by "fastboot devices" but
    echo actual Fastboot commands cannot reach it.
    echo.
    echo Reconnect the USB device to Windows and retry.
    goto :fail
)

rem ------------------------------------------------------------
rem Final confirmation.
rem ------------------------------------------------------------

echo ============================================================
echo UPGRADE WILL ERASE AND REFLASH BOOT + ROOTFS
echo ============================================================
echo.
echo This does NOT rewrite GPT or modem calibration partitions.
echo.
set "CONFIRM="
set /p "CONFIRM=Type FLASH exactly to continue: "
if /I not "%CONFIRM%"=="FLASH" goto :cancel

rem ------------------------------------------------------------
rem Stage 2 - boot.img
rem Same target and order as upstream.
rem ------------------------------------------------------------

echo.
echo [2/3] Flashing boot.img...
echo.

call :fb erase boot
if errorlevel 1 goto :fail

call :fb flash boot "%WORKDIR%\boot.img"
if errorlevel 1 goto :fail

rem ------------------------------------------------------------
rem Stage 3 - system.img -> rootfs
rem Keep upstream -S 200m behavior.
rem Large eMMC writes can take several minutes; do NOT reset while
rem a "Writing 'rootfs'" line is still active.
rem ------------------------------------------------------------

echo.
echo [3/3] Flashing system.img to rootfs...
echo.

call :fb erase rootfs
if errorlevel 1 goto :fail

echo.
echo IMPORTANT:
echo A rootfs "Writing" step may take several minutes.
echo Do NOT press RESET, disconnect USB, or move the device
echo while Fastboot is writing.
echo.

call :fb -S 200m flash rootfs "%WORKDIR%\system.img"
if errorlevel 1 goto :fail

echo.
echo Upgrade image flashing completed.
echo Rebooting...
echo.

call :fb reboot
if errorlevel 1 goto :fail

echo.
echo ============================================================
echo UPGRADE COMPLETED SUCCESSFULLY
echo ============================================================
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
echo.
echo Waiting for Fastboot...
echo If this UFI003 does not return automatically, keep USB
echo connected and long-press RESET to enter Fastboot again.
echo Do NOT hold RESET while plugging the USB cable.
echo.

for /L %%I in (1,1,180) do (
    call :detect_fastboot
    if not errorlevel 1 (
        echo Fastboot detected:
        echo   %FASTBOOT_SERIAL%
        exit /b 0
    )
    timeout /T 1 /NOBREAK >nul
)

echo ERROR: Fastboot did not appear within 180 seconds.
exit /b 1


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
echo UPGRADE STOPPED
echo ============================================================
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
