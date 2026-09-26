@echo off
setlocal
copy /Y "%~dp0StartupManager.previous.ps1" "%~dp0StartupManager.ps1" >nul
if errorlevel 1 (
  echo UI rollback failed.
) else (
  echo Previous UI restored. Launch the app again.
)
pause
