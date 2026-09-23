@echo off
rem Run ClipStack once, with a console window so errors are visible.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0ClipStack.ps1"
pause
