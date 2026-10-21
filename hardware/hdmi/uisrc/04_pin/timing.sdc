# 时序约束: 改编自 3_1_02_fpga_udp/02_udp_tri 例程 timing.sdc
# 实例名按 cvp_hdmi_top 调整 (pll0_inst→pll_gmii_inst, rgmii_interface_inst→u_rgmii_if)
create_clock -name sysclk -period 40.000 [get_ports {I_sys_clk}]
create_clock -name I_rgmii_rxc -period 8.000 -waveform {0 4} [get_ports {I_rgmii_rxc}]

derive_pll_clocks
rename_clock -name {a_tx_clk} -source [get_ports {I_sys_clk}] -master_clock {sysclk} [get_pins {pll_gmii_inst/pll_inst.clkc[0]}]
rename_clock -name {gmii_rxc} -source [get_ports {I_rgmii_rxc}] -master_clock {I_rgmii_rxc} [get_pins {u_rgmii_if/PLL2/pll_inst.clkc[0]}]
# 注: 原 UDP 例程还有 clk_25m/rgmii_rxc_int 两条 rename, 本设计这两个 PLL 输出
#     无负载被综合剪除, rename 目标不存在会报 USR-8176, 故删除(仅别名, 无功能)

create_generated_clock -name O_rgmii_txc -source [get_pins {pll_gmii_inst/pll_inst.clkc[0]}] -master_clock {a_tx_clk} -phase 0 -multiply_by 1 [get_ports {O_rgmii_txc}]

# CVP加: RX 采样时钟(PLL2 clk1, 源自 PHY RXC)与本地 125M(源自晶振)是真异步时钟。
# rgmii_cdc 内异步 FIFO 的 gray 指针跨域比较路径按同步检查会误报 ~10 条 setup 违例。
set_clock_groups -asynchronous -group [get_clocks {a_tx_clk}] -group [get_clocks {u_rgmii_if/PLL2/pll_inst.clkc[1]}]

# CVP加(跳动行/撕裂修复): 125M(晶振) 与 ddr_pll 150M 是真异步时钟 —— uidbuf 的
# W_REQ 已加两级同步(原裸采 f2d afull, STA 报 -0.884ns), f2d FIFO 指针/fs_cap 均为
# 设计的异步跨越。ddr_pll 三路输出(clk0/90°/其余)互为同步, 归同组保留内部同步分析。
# 注意: TD 的 set_clock_groups -group 不支持多时钟花括号列表(会解析成空组,
# 空组在 15:09 版 bit 中导致全时钟异步误声明, 画面冻结), 必须一时钟/group。
set_clock_groups -asynchronous -group [get_clocks {a_tx_clk}] -group [get_clocks {u_ddr_pll/pll_inst.clkc[0]}]
set_clock_groups -asynchronous -group [get_clocks {a_tx_clk}] -group [get_clocks {u_ddr_pll/pll_inst.clkc[1]}]
set_clock_groups -asynchronous -group [get_clocks {a_tx_clk}] -group [get_clocks {u_ddr_pll/pll_inst.clkc[2]}]

# CVP加(撕裂修复): ddr_pll 150M 与 hdmi_pll 75M/375M 是真异步时钟 —— uidbuf 读侧
# R_REQ 已加两级同步(原裸采 d2f aempty), d2f FIFO 指针/R 帧同步 fs_cap 为设计的
# 异步跨越。同 PLL 内部(clk0↔clk90 等)不声明, 保留同步分析。
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[0]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[0]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[0]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[1]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[0]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[2]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[1]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[0]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[1]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[1]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[1]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[2]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[2]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[0]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[2]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[1]}]
set_clock_groups -asynchronous -group [get_clocks {u_ddr_pll/pll_inst.clkc[2]}] -group [get_clocks {u_hdmi_pll/pll_inst.clkc[2]}]

set_input_delay -clock [get_clocks I_rgmii_rxc] -max 2.8 [get_ports {{I_rgmii_rxd[*]} I_rgmii_rx_ctl}]
set_input_delay -clock [get_clocks I_rgmii_rxc] -min 1.2 [get_ports {{I_rgmii_rxd[*]} I_rgmii_rx_ctl}]
set_input_delay -clock [get_clocks I_rgmii_rxc] -clock_fall -max -add_delay 2.800 [get_ports {{I_rgmii_rxd[*]} I_rgmii_rx_ctl}]
set_input_delay -clock [get_clocks I_rgmii_rxc] -clock_fall -min -add_delay 1.200 [get_ports {{I_rgmii_rxd[*]} I_rgmii_rx_ctl}]

# CVP删: 原 TX set_output_delay 两条 —— 本设计纯接收(发送请求恒0, TX数据恒0),
# 例程的 TX 输出约束导致 14 setup + 9 hold 违例(O_rgmii_txd 路径), 无功能意义, 移除。
# TX 仍保留 ODDR 驱动恒0, PHY 侧永不发帧。

# CVP加: ARP 层只服务发送(缓存目的MAC), 本设计纯接收不发送(I_W_udp_req=0),
# 其 mac_cache 组合链(10.3ns)在 125M 下必违例且无功能影响, 整层 false_path。
set_false_path -to [get_cells -hierarchical *arp_layer_inst*]

# CVP改: 指针已寄存器化(shift_xxaddr 打一拍), FIFO 使能链为纯同域 FF->减法->比较,
# 撤销免责让其受真正时序约束(免检会被布线器糊弄)。gray 同步器路径已由上方
# set_clock_groups 异步声明覆盖。
