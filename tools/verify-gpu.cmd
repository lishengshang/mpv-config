@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-gpu.ps1" -Run
set "result=%errorlevel%"
pause
exit /b %result%
