@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-vs-runtime.ps1"
set "result=%errorlevel%"
pause
exit /b %result%
