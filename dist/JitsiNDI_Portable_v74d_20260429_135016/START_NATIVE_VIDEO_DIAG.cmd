@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0build\Release;%~dp0;%PATH%"
if not exist logs mkdir logs
set /p ROOM=Room or full Jitsi link: 
set /p NICK=Nick (empty for default): 
if "%NICK%"=="" (
  "%~dp0build\Release\jitsi-ndi-native.exe" --room "%ROOM%" 1>"%~dp0logs\native_video_diag.log" 2>&1
) else (
  "%~dp0build\Release\jitsi-ndi-native.exe" --room "%ROOM%" --nick "%NICK%" 1>"%~dp0logs\native_video_diag.log" 2>&1
)
echo.
echo Native exited. Log: %~dp0logs\native_video_diag.log
pause
