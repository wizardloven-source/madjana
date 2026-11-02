@echo off
setlocal
cd /d C:\Users\MTC\Desktop\madjana\apps\mobile
echo === Starting Mobile Build === >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log
echo Time: %date% %time% >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log
call flutter clean >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log 2>&1
call flutter pub get >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log 2>&1
call flutter build apk --release >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log 2>&1
echo === Build Exit Code: %errorlevel% === >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log
echo Time: %date% %time% >> C:\Users\MTC\Desktop\madjana\build_jobs\mobile_build_trace.log
exit /b %errorlevel%
