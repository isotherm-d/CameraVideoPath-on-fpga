#!/bin/bash
# PLL2 CLKC1_CPHASE 盲扫: 改相位 → 调 build_check.tcl 重新综合布局布线
# 用法: ./sweep_cphase.sh <值>   (合法 1..8; 8 等效 0 度; 当前板上=5 已知失败)
# 每次改完需在 TD(TD GUI 须关闭) 重跑编译并烧录, 然后 PC 跑 eth_bar_tx.py 看 LED3/LED2
V="$1"
if [ -z "$V" ]; then echo "用法: $0 <CPHASE 1..8>"; exit 1; fi
cd "$(dirname "$0")/.."
F=uisrc/03_ip/al_pll/PLL2.v
python - "$V" <<'PY'
import sys, re
v = sys.argv[1]
p = 'uisrc/03_ip/al_pll/PLL2.v'
s = open(p, encoding='gbk', errors='surrogateescape').read()
new = ".CLKC1_CPHASE(%s)," % v
s2, n = re.subn(r"\.CLKC1_CPHASE\(\d+\),", new, s)
assert n == 1, n
open(p, 'w', encoding='gbk', errors='surrogateescape').write(s2)
print("PLL2.v CLKC1_CPHASE -> %s" % v)
PY
echo "下一步: 关闭 TD GUI(如开着) → td 命令行跑 build_check.tcl → 烧录 →"
echo "  PC: python HDMI_OUT/tools/../.. 见 eth_bar_tx.py 持续发包 → 看 LED3 闪/LED2 灭 + HDMI 出图"
