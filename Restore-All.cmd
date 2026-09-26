@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StartupManager.ps1" -RestoreAll
pause
