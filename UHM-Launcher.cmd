@echo off
setlocal
cd /d "%~dp0"
where powershell >nul 2>&1 || (echo PowerShell is required.&pause&exit /b 1)
echo.
echo  UHM Launcher - Assetto Corsa Mod Hub
echo  1. Open web catalog
 echo 2. Install a mod from catalog
 echo 3. Find Assetto Corsa paths
 echo 4. Exit
choice /c 1234 /n /m "Select: "
if errorlevel 4 exit /b
if errorlevel 3 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\UHM-Core.ps1" -Action FindPaths
if errorlevel 2 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\UHM-Core.ps1" -Action Install
if errorlevel 1 start "UHM Catalog" "%~dp0ui\index.html"
endlocal
