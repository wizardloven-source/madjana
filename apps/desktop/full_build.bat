@echo off
cd /d "C:\\Users\\MTC\\Desktop\\madjana\\apps\\desktop"
flutter clean
flutter pub get
flutter build windows --release -v

& flutter build windows --release -v > "C:\\Users\\MTC\\Desktop\\madjana\\build_jobs\\desktop_build.log" 2>&1
