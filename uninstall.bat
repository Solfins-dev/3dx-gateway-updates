@echo off
REM ============================================================
REM Solfins 3DX Gateway -- uninstall / clean-slate wrapper.
REM
REM Use this to fully remove a previous (or half-finished) install
REM before re-running install.bat:
REM   1. Right-click -> Run as administrator
REM      (or double-click and accept the UAC prompt).
REM
REM This script:
REM   - Self-elevates if not launched as Administrator.
REM   - Runs uninstall.ps1 from the SAME folder if present (works offline
REM     on a broken box); otherwise downloads it from the Solfins mirror.
REM   - Tears down containers + volumes + the helper task + the install and
REM     state dirs. It NEVER stops IIS or any other service.
REM   - Pauses at the end so you can read the output.
REM
REM Flags you can append after uninstall.bat (optional):
REM   -KeepData       keep the database + settings (Docker volumes)
REM   -RemoveImages   also delete the pulled Docker images
REM   -Yes            no confirmation prompt
REM ============================================================

setlocal

REM --- self-elevate if not Admin ---
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [info] Re-launching elevated... accept the UAC prompt.
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs -ArgumentList '%*'"
    exit /b 0
)

title 3DX Gateway Uninstaller (Solfins)

set "PS1_LOCAL=%~dp0uninstall.ps1"
set "PS1_URL=https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/uninstall.ps1"
set "PS1_TEMP=%TEMP%\3dx-gateway-uninstall.ps1"

echo.
echo === Solfins 3DX Gateway Uninstaller ===
echo.

if exist "%PS1_LOCAL%" (
    echo Using local uninstall.ps1 next to this wrapper.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_LOCAL%" %*
    set "UN_EXIT=%ERRORLEVEL%"
) else (
    echo Local uninstall.ps1 not found; downloading from public mirror...
    echo   %PS1_URL%
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Invoke-WebRequest -UseBasicParsing -Uri '%PS1_URL%' -OutFile '%PS1_TEMP%'"
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo [ERROR] Download failed. Check internet connection / firewall and try again.
        pause
        exit /b 1
    )
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_TEMP%" %*
    set "UN_EXIT=%ERRORLEVEL%"
)

echo.
if %UN_EXIT% EQU 0 (
    echo === Uninstall finished. ===
) else (
    echo === Uninstall exited with code %UN_EXIT% -- scroll up for details. ===
)
echo.
echo Press any key to close this window...
pause >nul

endlocal
exit /b %UN_EXIT%
