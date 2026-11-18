@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build_TaskPilot_STEP3_6F_4.ps1"
set "BuildResult=%ERRORLEVEL%"
pause
exit /b %BuildResult%
