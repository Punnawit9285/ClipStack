@echo off
setlocal
set "VBS=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ClipStack.vbs"
if exist "%VBS%" del "%VBS%" && echo Removed startup entry.

rem The startup .vbs exits as soon as it has launched PowerShell, so the process
rem to stop is the powershell.exe running ClipStack.ps1 (not this one, whose own
rem command line mentions ClipStack.ps1 too).
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*ClipStack.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; 'Stopped ClipStack.' }"

echo.
echo History is kept at: %LOCALAPPDATA%\ClipStack
echo Delete it with: rmdir /s /q "%LOCALAPPDATA%\ClipStack"
pause
endlocal
