@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul 2>&1
title UHM Launcher

set "UHM_ROOT=%~dp0"
set "UHM_CORE=%UHM_ROOT%core\UHM-Core.ps1"

if not exist "%UHM_CORE%" (
  echo [UHM] فایل هسته پیدا نشد: "%UHM_CORE%"
  pause
  exit /b 2
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [UHM] Windows PowerShell پیدا نشد.
  pause
  exit /b 3
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ok = $env:OS -eq 'Windows_NT' -and [Environment]::OSVersion.Version.Major -ge 10 -and $PSVersionTable.PSVersion -ge [Version]'5.1'; if ($ok) { exit 0 } else { exit 1 }"
if errorlevel 1 (
  echo [UHM] این برنامه فقط روی Windows 10 یا Windows 11 و PowerShell 5.1 اجرا می‌شود.
  pause
  exit /b 4
)

echo [UHM] در حال راه‌اندازی رابط گرافیکی Native (WPF)...
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%UHM_CORE%" -Action launch
set "UHM_EXIT=%ERRORLEVEL%"
if not "%UHM_EXIT%"=="0" (
  echo.
  echo [UHM] اجرای لانچر با خطا پایان یافت. پوشه data\logs را بررسی کنید.
  pause
)
exit /b %UHM_EXIT%
