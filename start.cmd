@echo off
setlocal
rem Official Gufo launcher. Python is not required.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\windows\launcher.ps1" %*
set "GUFO_LAUNCH_EXIT=%ERRORLEVEL%"
if not "%GUFO_LAUNCH_EXIT%"=="0" (
  echo.
  echo Launcher failed. See the message above. Press any key to close.
  pause >nul
)
exit /b %GUFO_LAUNCH_EXIT%
