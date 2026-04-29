@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0build\Release;%~dp0;%PATH%"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0JitsiNdiGui.ps1"
