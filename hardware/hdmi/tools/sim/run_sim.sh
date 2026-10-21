#!/bin/bash
# HDMI_OUT 网口→视频流 ModelSim 仿真一键脚本
# 用法: ./run_sim.sh [场景名...]   (默认跑 manifest.txt 全部场景)
# 每次 vsim 前清掉 vopt 缓存(_opt*), 杜绝陈旧优化设计导致的假结果
set -e
cd "$(dirname "$0")"
M=/c/modeltech64_2020.4/win64

RTL="../../uisrc/01_rtl/cvp_rx_assemble.v ../../uisrc/01_rtl/rgmii_cdc.v \
../../uisrc/03_ip/al_softfifo/udp_pkg_buf.v ../../uisrc/03_ip/shiftram/shift_ram_8bit.v"
for f in ../../uisrc/03_ip/uiudp_stack/*.v; do
    case "$f" in
        *rgmii_interface.v|*uirgmii_rx.v|*uirgmii_tx.v) ;;   # RGMII 原语层, 仿真不含
        *) RTL="$RTL $f" ;;
    esac
done

if [ ! -d work ]; then "$M/vlib.exe" work >/dev/null; fi
echo "== 编译 RTL + TB =="
"$M/vlog.exe" -quiet $RTL tb_cvp_net2vid.v

SCEN="$@"
if [ -z "$SCEN" ]; then
    SCEN=$(awk '{print $1}' manifest.txt)
fi

PW=$(pwd -W 2>/dev/null || pwd)
PASS=0; FAIL=0
for s in $SCEN; do
    NF=$(awk -v s="$s" '$1==s{print $2}' manifest.txt)
    EB=$(awk -v s="$s" '$1==s{print $3}' manifest.txt)
    rm -rf _opt _opt1                          # 强制重新优化
    echo "== 场景 $s (观察帧=$NF, 跳过=2, crc_bad期望=$EB) =="
    if "$M/vsim.exe" -c -quiet -voptargs=+acc work.tb_cvp_net2vid \
        "+STIM=$PW/stim_$s.hex" "+EXP=$PW/exp_$s.hex" \
        "+NFRAMES=$NF" "+EXPBAD=$EB" "+SKIPFRAMES=2" \
        -do "run -all; quit -f" 2>&1 | grep -qE "\*\*\* PASS \*\*\*"; then
        echo "   -> PASS"; PASS=$((PASS+1))
    else
        echo "   -> FAIL"; FAIL=$((FAIL+1))
    fi
done
echo "== 汇总: PASS=$PASS FAIL=$FAIL =="
