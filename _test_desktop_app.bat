@echo off
setlocal
cd /d C:\Users\MTC\Desktop\madjana\apps\desktop
timeout /t 20 /nobreak >nul
tasklist /FI "IMAGENAME eq madjana_desktop.exe" 2>nul | find "madjana_desktop.exe" >nul
if errorlevel 1 (
    echo App has exited
) else (
    echo App is still running after 20s
    taskkill /F /IM madjana_desktop.exe 2>nul
)
exit /b 0
