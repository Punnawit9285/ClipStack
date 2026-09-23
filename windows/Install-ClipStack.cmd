@echo off
setlocal
rem Register ClipStack to start with Windows, then launch it.
set "HERE=%~dp0"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS=%STARTUP%\ClipStack.vbs"

if not exist "%HERE%ClipStack.ps1" (
    echo ERROR: ClipStack.ps1 not found next to this installer.
    pause
    exit /b 1
)

rem A .vbs launcher starts PowerShell with no console window flashing up.
> "%VBS%" echo Set s = CreateObject("WScript.Shell")
>>"%VBS%" echo s.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -File ""%HERE%ClipStack.ps1""", 0, False

echo Startup entry written to:
echo   %VBS%
echo.
start "" wscript.exe "%VBS%"
echo ClipStack is starting. Look for its icon in the notification area.
echo.
echo   Ctrl+Shift+V   open the picker
echo   Ctrl+Shift+N   load the next queued clip
echo.
pause
endlocal
