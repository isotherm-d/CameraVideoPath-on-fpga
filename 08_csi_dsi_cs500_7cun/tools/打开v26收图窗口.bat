@echo off
rem ============================================
rem  Camera UDP Receiver Launcher (1280x720@30fps)
rem  Board: 192.168.1.66 -> PC 192.168.1.100 UDP 6000
rem  Keys:  s = save frame   q / ESC = quit
rem  GUI sliders apply automatically after 250ms (debounce)
rem ============================================
title Camera GUI - 1280x720@30fps
cd /d "%~dp0"

echo Starting camera GUI (video + exposure/white-balance controls) ...
echo   expect 1280x720 RGB888, 1440B/packet x 1920 packets/frame
echo   make sure PC NIC = 192.168.1.100/24 and firewall allows UDP 6000 and 6002
echo.

python cam_gui_v26.py

echo.
echo Receiver exited.
pause
