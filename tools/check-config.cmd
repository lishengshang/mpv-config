@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-config.ps1"
set "result=%errorlevel%"
pause
exit /b %result%
