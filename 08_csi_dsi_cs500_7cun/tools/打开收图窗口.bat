@echo off
rem ============================================
rem  Camera UDP Receiver Launcher (1024x600@20fps)
rem  Board: 192.168.1.66 -> PC 192.168.1.100 UDP 6000
rem  Keys:  s = save frame   q / ESC = quit
rem ============================================
title Camera UDP Receiver - 1024x600
cd /d "%~dp0"

echo Starting eth_video_rx.py ...
echo   expect 1024x600 RGB888, 1440B/packet x 1280 packets/frame
echo   make sure PC NIC = 192.168.1.100/24 and firewall allows UDP 6000
echo.

python eth_video_rx.py --width 1024 --height 600

echo.
echo Receiver exited.
pause
