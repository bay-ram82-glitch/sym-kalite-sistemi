@echo off
title KALITE SISTEMI BASLATMA

echo ===============================
echo  KALITE SISTEMI BASLATIYOR...
echo ===============================
echo.

REM 1) API klasorune gec
cd /d C:\kalite_api

REM 2) API'yi ayri bir pencerede baslat
echo [1/3] Python API baslatiliyor...
start "Kalite API" cmd /k "cd /d C:\kalite_api && python api.py"

REM 3) ADB reverse ayarla
echo [2/3] ADB reverse ayarlaniyor...
set ADB="%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"

if exist %ADB% (
  %ADB% devices
  %ADB% reverse tcp:5000 tcp:5000
) else (
  echo HATA: adb.exe bulunamadi.
  echo Beklenen yol: %LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe
  echo Android SDK platform-tools kurulu mu kontrol edin.
  pause
  exit /b 1
)

echo.
echo [3/3] ISLEM TAMAM.
echo Tablet uygulamasini acabilir ve VIN sorgulayabilirsiniz.
echo.
pause