@echo off
rem ============================================
rem  Camera UDP Receiver Launcher (1280x720@30fps)
rem  Board: 192.168.1.66 -> PC 192.168.1.100 UDP 6000
rem  Keys:  s = save frame   q / ESC = quit
rem  GUI sliders apply automatically after 250ms (debounce)
rem ============================================
setlocal
title Camera GUI v27 - 1280x720@30fps
cd /d "%~dp0"

rem ---- capture NIC check/fix: PC must be 192.168.1.100/24 (UAC on change) ----
set WANTIP=192.168.1.100
set CURIP=
for /f %%I in ('powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -like '192.168.1.*'} | Select-Object -First 1).IPAddress"') do set CURIP=%%I
if "%CURIP%"=="%WANTIP%" goto ipok

echo.
echo [WARN] capture NIC IP = "%CURIP%", want %WANTIP% - fixing (elevate, UAC prompt) ...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'FIXIP' -Verb RunAs -Wait"
timeout /t 3 /nobreak >nul
set CURIP=
for /f %%I in ('powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -like '192.168.1.*'} | Select-Object -First 1).IPAddress"') do set CURIP=%%I
echo [INFO] capture NIC IP now = "%CURIP%"
if not "%CURIP%"=="%WANTIP%" echo [WARN] fix failed - GUI will start anyway, check NIC manually.

:ipok
echo [INFO] capture NIC = "%CURIP%"

echo Starting camera GUI (video + exposure/white-balance controls) ...
echo   expect 1280x720 RGB888, 1440B/packet x 1920 packets/frame
echo   make sure PC NIC = 192.168.1.100/24 and firewall allows UDP 6000 and 6002
echo.

python cam_gui_v27.py

echo.
echo Receiver exited.
pause
exit /b

rem ---- elevated: fix capture NIC (called with FIXIP from the main flow) ----
if /i "%1"=="FIXIP" (
    set FIXIDX=
    for /f %%I in ('powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -like '192.168.1.*'} | Select-Object -First 1).InterfaceIndex"') do set FIXIDX=%%I
    if not "%FIXIDX%"=="" (
        netsh interface ipv4 delete neighbors %FIXIDX%
        netsh interface ipv4 set address %FIXIDX% static 192.168.1.100 255.255.255.0
    )
    exit /b
)
