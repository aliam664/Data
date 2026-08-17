@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul 2>&1
title UHM Catalog Manager

set "UHM_CATALOG_DIR=%~dp0"
set "UHM_MANAGER=%UHM_CATALOG_DIR%UHM-Catalog-Manager.ps1"

if not exist "%UHM_MANAGER%" (
  echo [UHM Catalog] فایل مدیریت کاتالوگ پیدا نشد.
  pause
  exit /b 2
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [UHM Catalog] Windows PowerShell 5.1 پیدا نشد.
  pause
  exit /b 3
)

echo [UHM Catalog] در حال باز کردن مدیریت گرافیکی کاتالوگ...
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%UHM_MANAGER%"
set "UHM_EXIT=%ERRORLEVEL%"
if not "%UHM_EXIT%"=="0" (
  echo.
  echo [UHM Catalog] برنامه با خطا بسته شد.
  pause
)
exit /b %UHM_EXIT%
