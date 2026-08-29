@echo off
chcp 65001 >nul
title Building Poultry Mobile App

set PATH=C:\flutter\bin;%PATH%

echo ========================================
echo Starting Build Process...
echo.

echo Step 1: Killing Kotlin Daemon...
taskkill /F /IM kotlin-daemon.exe 2>nul
taskkill /F /IM java.exe 2>nul
taskkill /F /IM gradle.exe 2>nul
echo Done.
echo.

echo Step 2: Clearing Gradle cache...
rmdir /s /q C:\Users\MTC\.gradle\caches 2>nul
echo Done.
echo.

echo Step 3: Changing directory...
cd /d C:\Users\MTC\Desktop\madjana\apps\mobile
echo Current directory: %cd%
echo.

echo Step 4: Cleaning project...
flutter clean
echo Done.
echo.

echo Step 5: Getting packages...
flutter pub get
echo Done.
echo.

echo Step 6: Building APK...
set GRADLE_OPTS=-Dorg.gradle.daemon=false
flutter build apk --debug
echo Done.
echo.

echo ========================================
echo BUILD COMPLETE!
echo APK: build\app\outputs\flutter-apk\app-debug.apk
echo ========================================
pause