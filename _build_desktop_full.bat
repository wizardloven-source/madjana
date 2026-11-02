@echo off
cd /d C:\Users\MTC\Desktop\madjana\apps\desktop
flutter clean
flutter pub get
flutter build windows --release
echo DESKTOP_BUILD_COMPLETE
pause
