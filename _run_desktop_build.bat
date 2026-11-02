@echo off
setlocal
cd /d C:\Users\MTC\Desktop\madjana\apps\desktop
echo === Starting Desktop Build === >> C:\Users\MTC\Desktop\madjana\build_jobs\desktop_build_trace.log
echo Time: %date% %time% >> C:\Users\MTC\Desktop\madjana\build_jobs\desktop_build_trace.log
call C:\flutter\bin\flutter.bat build windows --release >> C:\Users\MTC\Desktop\madjana\build_jobs\desktop_build_trace.log 2>&1
echo === Build Exit Code: %errorlevel% === >> C:\Users\MTC\Desktop\madjana\build_jobs\desktop_build_trace.log
echo Time: %date% %time% >> C:\Users\MTC\Desktop\madjana\build_jobs\desktop_build_trace.log
exit /b %errorlevel%
