@echo off
setlocal DisableDelayedExpansion
set "VSSCRIPT_PATH="
if not exist "%~dp0VSScript.dll" goto play
"%SystemRoot%\System32\findstr.exe" /b /l /c:"script-opts-append=extensions-rtx=yes" "%~dp0portable_config\state\rtx.conf" >nul 2>nul
if not errorlevel 1 set "VSSCRIPT_PATH=%~dp0VSScript.dll"
:play
"%~dp0mpv.exe" --player-operation-mode=pseudo-gui %*
exit /b %ERRORLEVEL%
