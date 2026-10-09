#!/bin/bash
# RGMII DDR 层仿真: 引脚级激励 → rgmii_interface(PLL2+IDDR) → 下游原链
# 需 TD 的安路行为仿真库(sim_release/eg + common/al_phy_glbl.v)
# 用法: ./run_ddr_sim.sh [场景名...]   (默认 manifest 全部)
set -e
cd "$(dirname "$0")"
M=/c/modeltech64_2020.4/win64
TD_SIM="C:/Anlogic/TD5.6.59063/sim_release"

RTL="../../uisrc/01_rtl/cvp_rx_assemble.v ../../uisrc/01_rtl/rgmii_cdc.v \
../../uisrc/03_ip/uiudp_stack/rgmii_interface.v \
pll2_sim.v \
../../uisrc/03_ip/al_softfifo/udp_pkg_buf.v ../../uisrc/03_ip/shiftram/shift_ram_8bit.v"
for f in ../../uisrc/03_ip/uiudp_stack/*.v; do
    case "$f" in
        *uirgmii_rx.v|*uirgmii_tx.v|*rgmii_interface.v) ;;                 # 仅 TX/RX 序列化子层, 本链不用
        *) RTL="$RTL $f" ;;
    esac
done

rm -rf work_ddr lib_ddr _opt_ddr _opt_ddr1
"$M/vlib.exe" work_ddr >/dev/null
"$M/vlib.exe" lib_ddr >/dev/null
echo "== 编译 安路仿真库(全量 eg) + RTL + TB =="
"$M/vlog.exe" -quiet -work lib_ddr "$TD_SIM/eg/"*.v
"$M/vlog.exe" -quiet -work work_ddr "$TD_SIM/common/al_phy_glbl.v"
"$M/vlog.exe" -quiet -work work_ddr $RTL tb_rgmii_ddr.v

SCEN="$@"
if [ -z "$SCEN" ]; then
    SCEN=$(awk '{print $1}' manifest.txt)
fi

PW=$(pwd -W 2>/dev/null || pwd)
PASS=0; FAIL=0
for s in $SCEN; do
    NF=$(awk -v s="$s" '$1==s{print $2}' manifest.txt)
    EB=$(awk -v s="$s" '$1==s{print $3}' manifest.txt)
    echo "== DDR 场景 $s (观察帧=$NF, crc_bad期望=$EB) =="
    if "$M/vsim.exe" -c -quiet -voptargs=+acc -L lib_ddr work_ddr.tb_rgmii_ddr \
        "+STIM=$PW/stim_$s.hex" "+EXP=$PW/exp_$s.hex" \
        "+NFRAMES=$NF" "+EXPBAD=$EB" "+SKIPFRAMES=2" \
        -do "run -all; quit -f" 2>&1 | grep -qE "\*\*\* PASS \*\*\*"; then
        echo "   -> PASS"; PASS=$((PASS+1))
    else
        echo "   -> FAIL"; FAIL=$((FAIL+1))
    fi
done
echo "== DDR 汇总: PASS=$PASS FAIL=$FAIL =="
