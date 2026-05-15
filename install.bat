@echo off
REM ============================================================
REM Solfins 3DX Gateway -- one-click installer wrapper.
REM
REM Customer flow:
REM   1. Download install.bat (single ~1 KB file).
REM   2. Right-click -> Run as administrator
REM      (or just double-click and accept the UAC prompt that pops up).
REM
REM This script:
REM   - Self-elevates if not launched as Administrator.
REM   - Downloads the latest install.ps1 from the Solfins public mirror.
REM   - Runs it with ExecutionPolicy Bypass so unsigned-script blocks
REM     don't bite the customer.
REM   - Pauses at the end so the window stays open (you can read errors
REM     before it closes if anything went wrong).
REM
REM Equivalent PowerShell one-liner (paste into elevated PowerShell):
REM
REM   Set-ExecutionPolicy Bypass -Scope Process -Force; ^
REM     irm https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.ps1 ^
REM     -OutFile $env:TEMP\install.ps1; ^
REM     ^& $env:TEMP\install.ps1
REM ============================================================

setlocal

REM --- self-elevate if not Admin ---
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [info] Re-launching elevated... accept the UAC prompt.
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b 0
)

title 3DX Gateway Installer (Solfins)

set "PS1_URL=https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.ps1"
set "PS1_LOCAL=%TEMP%\3dx-gateway-install.ps1"

echo.
echo === Solfins 3DX Gateway Installer ===
echo.
echo Step 1/2 - downloading install.ps1 from public mirror...
echo   %PS1_URL%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Invoke-WebRequest -UseBasicParsing -Uri '%PS1_URL%' -OutFile '%PS1_LOCAL%'"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Download failed. Check internet connection / firewall and try again.
    pause
    exit /b 1
)
echo   Downloaded to %PS1_LOCAL%

echo.
echo Step 2/2 - running installer (interactive prompts follow)...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_LOCAL%"
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
if %INSTALL_EXIT% EQU 0 (
    echo === Installer finished. ===
) else (
    echo === Installer exited with code %INSTALL_EXIT% -- scroll up for details. ===
)
echo.
echo Press any key to close this window...
pause >nul

endlocal
exit /b %INSTALL_EXIT%
