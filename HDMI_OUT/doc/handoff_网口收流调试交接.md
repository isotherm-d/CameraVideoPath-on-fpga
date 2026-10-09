# HANDOFF：EG4D 副板网口收流 → HDMI 调试交接

> 日期: 2026-10-09 凌晨 | 工程: `cvp/CameraVideoPath-on-fpga/HDMI_OUT`（TD5.6，EG4D20EG176，MLKPAI-F01 板）
> 现状: **HDMI 链路已验证正常（彩条上屏）；网口→DDR 链路卡在"MAC 层收到字节但所有帧 CRC 失败/帧长异常"**
> 本文供接手人（人或下一个会话）继续。所有结论都有板级 LED 证据，非猜测。

---

## 1. 系统与目标

```
PH1P35 主板(摄像头) ──ETHA──> PC(控制+预览)          【已工作】
        └─ETHB(镜像ETHA的RGMII TX) ──网线──> EG4D副板 ──> HDMI 出相机画面   ← 本调试
```

- 主板侧 ETHB 镜像已实现并烧录（`08_csi_dsi_cs500_7cun/design_top_wrapper.v` 末尾 assign 复制 + `pin.adc` ETHB 7 引脚），**用户确认主板 ETHB 发包正常**（PC 能收到）
- 副板：YT8531 PHY(RGMII) → 米联客 uiudp_stack(改为纯接收) → cvp_rx_assemble(自研重组器) → uidbuf 三缓冲 → 合封 DDR1 → uivtc/uihdmitx → HDMI
- 副板纯接收：无命令通路、TX 恒 0、无 ARP/ICMP 响应（ping 不通正常）

## 2. 当前板上 bit 的 LED 语义（烧录版 = LED2 接 lenbad）

| LED | 引脚 | 信号 | 正常预期 |
|---|---|---|---|
| LED0 | P91 | 心跳 1.5Hz | 闪 ✓ |
| LED1 | P104 | `rx_valid` 字节计数 bit24（CDC 出口=MAC 入口） | 闪 ✓（实测闪） |
| LED2 | P109 | `w_lenbad` 帧长异常计数 bit10（帧长∉[1480,1510]） | **应常亮（恒0），实测闪=异常** |
| LED3 | P112 | `udp_rx_valid` 字节计数 bit24（UDP 出口） | 应闪，**实测恒 0** |

板载 LED 低电平点亮：**常亮=信号恒 0，闪烁=有活动**。

## 3. 证据链（按时间，全部实测）

| # | 实验 | 结果 | 结论 |
|---|---|---|---|
| 1 | GEN_TESTPAT=1 彩条 | **屏幕出 8 竖彩条** | PLL×4/VTC/TMDS/HDMI 引脚/DDR 读侧全通 |
| 2 | GMII 活动灯(LED2旧) | 闪 | PHY→RGMII→IDDR→CDC 有字节流 |
| 3 | RGMII 移相修复后, 前导特征计数(55/D5/AA/5D) 窗口=帧头12B | **55 闪、D5 闪、AA/5D 恒0** | **字节对齐正确**（SFD 都对），移相修复有效 |
| 4 | PC 直发(192.168.1.66→.100, ARP绑02-1A-2B-3C-4D-5F) | 网卡实测 5.45MB/s 上线 | PC 侧发包链路 OK（此前 Windows 环回+广播ARP 两个坑已排） |
| 5 | crc_ok/crc_bad 分灯 | crc_ok 恒0, **crc_bad 闪** | 帧走完 MAC 全流程(SFD/DA/Type/长度判定都过)但 **CRC 全错** |
| 6 | --gap 8us 拉开帧距 | crc_bad/lenbad 照旧闪 | 与背靠背帧间隙无关，**错在单帧内部** |
| 7 | lenbad 分灯（当前） | **闪**（帧距无关） | 帧长也乱 → 字节流在帧中后部丢/错字节，非帧边界问题 |

**矛盾点（核心谜题）**：帧头 12 字节逐字节正确（证据3），但整帧 CRC 全错（证据5）。→ 字节错位/丢失发生在**帧内第 13 字节之后**的某处，且是系统性（100% 帧失败，不是抖动）。

## 4. 已做的全部修复（勿重复尝试）

**副板 RTL（HDMI_OUT/uisrc）**
1. `uimac_rx.v`：广播分支放行 ARP+IP（视频流 DA=广播；IP 层有目的 IP 二次过滤）
2. `uimac_layer.v`：例程笔误 `.rst(reset)`→`.rst(I_mac_reset)`（未声明信号被填 0）
3. `uimac_rx.v`：加 `o_dbg_crc_ok/crc_bad/lenbad` 计数器（穿层 uimac_layer→uiudp_stack→顶层）
4. `rgmii_interface.v`：**RX 采样时钟移相**——PLL2 clk1(CPHASE 7→5, -2ns) 作 IDDR 采样钟（参数 `RX_CLK_PHASE_SEL`，0=回退）；删除例程遗留多驱动 `assign rgmii_rxc_int=gmii_rx_clk`；引出 `o_gmii_rx_sample_clk`；前导特征计数器（o_dbg_cnt55/d5/aa/5d）
5. `PLL2.v`：clk1 加 BUFG（原来裸线）；CPHASE 5
6. `rgmii_cdc` 例化：`I_gmii_rclk` 改接 `gmii_rx_sample_clk`（与字节流同域——**关键修复**，此前跨相采样）
7. `udp_pkg_buf.v`：full 侧指针（shift_rdaddr，写域）寄存一拍——消灭 10ns 组合链（wea 路径）；**empty 侧保持组合**（v1 曾两侧都寄存=方向错误，导致水位虚高，v2 已纠正）
8. `cvp_rx_assemble.v`（自研重组器）：r_bcnt 双重赋值 bug（w_bcnt 组合化）；FS 拉宽 64 拍+消隐 512 拍（uidbuf fs_cap 是 150M 域边沿检测+S_RST FIFO 复位窗）；staging FIFO empty_flag 接线；**w_in_frame 界内判定写反**（原式 `{~offset[31],…}` 把 bit31=0 的正常包恒判界外——MAC 层修好后会 100% 丢包、rx_frame_cnt 恒 0，已改为 `offset ≤ FRAME_BYTES−DATA_BYTES` 无符号比较，2026-10-09 对照 PC 脚本 frame_tools.py 审出）；offset%3 检查升级为缺口白名单 {0..4}×1440（归纳保证整包对齐；%3 会放行 1443 类非包边界乱值造成像素错位）
9. `cvp_hdmi_top.v`：uidbuf 24→**32bit** 通路（24bit 使 BRAM 深度=1536 非法，EG4 只许 512/1k/2k/4k/8k）；LED 分诊矩阵多次迭代
10. 约束：TX output_delay 删除（纯接收）；`set_clock_groups -asynchronous a_tx_clk vs PLL2 clk1`；ARP false_path **语法已修正为 `-hierarchical` 但尚未重编验证**；FIFO false_path 已撤销（指针寄存后应真收敛）

**工程/环境坑（重要！）**
- TD GUI 开着工程时：外部改 `.al` 会被覆盖；外部改 RTL 后必须 **Close Project → Reopen** 再综合
- TD 对语法错误的文件会打 `AutoExcluded=true` **静默排除出编译**（黑盒循环的根源），标记持久化在 `.al`，需手工清；已清 3 轮
- 命令行编译：`build_check.tcl`（open_project→launch_runs syn_1 phy_1），GUI 开着时 CLI 静默不跑
- PH1P35 主板工程要用 TD6.2.1（TD5.6 报 Unknown device）；EG4D 副板两个版本都行，用户用 5.6

**PC 测试环境（当前状态）**
- 网卡"以太网"(ifIndex 17) IP 已改 **192.168.1.66/24**（原 192.168.1.100 是接主板 ETHA 控制用的，**测完要改回**：`netsh interface ipv4 set address name="以太网" source=static address=192.168.1.100 mask=255.255.255.0`，需管理员）
- ARP 静态绑定 `192.168.1.100 = 02-1A-2B-3C-4D-5F`（副板协议栈本地 MAC；**必须单播 MAC**，Windows 拒绝向广播 MAC 静态表项发单播；曾残留 Incomplete 表项需 Remove-NetNeighbor 清掉）
- 发包脚本 `tools/eth_bar_tx.py --fps 2 --gap 8` 后台运行中（2fps 彩条流，8µs 包间隔）
- 时序现状：12 setup 违例 = 9 条 ARP 死逻辑（arp_tx→mac_cache，无功能，false_path 语法已修待重编）+ DDR/uiphyrst/uidbuf 例程固有（**UDP 例程官方编译自身就带 9 setup+6 hold 同款路径**，带病工作）

## 5. 下一步（按优先级）

**① 对齐探针（已设计，补丁未打上——上次锚文本失配 assert 失败，顶层文件仍是 lenbad 状态）**
在顶层用 `rx_valid/rx_data`（MAC 入口）对比帧内字节 26-29 = PC 的源 IP `C0 A8 01 42`（192.168.1.66）：
- 全对 → 前 26 字节正确，错位在帧中后部 → 指向 MAC 内部 FIFO/CRC 流水
- 有错 → CDC 出口到 MAC 之间就错 → 指向 rgmii_cdc 内部
注意锚文本：先 grep 顶层实际 LED 段头（多次迭代后注释已变），别用旧锚。

**② ChipWatcher 抓字节（一锤定音）**
PC 发的内容完全已知（55×7+D5+确定头+彩条数据）。在 `rx_valid` 上升沿触发，抓 CDC 出口 `rx_data` 64 字节，与预期逐字节比对：
- 若错位从固定偏移开始（如每 N 字节丢/插 1 字节）→ 指向 DDR 采样窗残留偏移（试 PLL2 CPHASE 反向=9 或 IDDELAY 微调）
- 若随机错 → 时序/CDC 问题

**③ 备选试验（各 10 分钟）**
- `PLL2.v` CLKC1_CPHASE 5→9（反方向 2ns）重试——当前 5 是猜的方向
- `rgmii_interface` 参数 `RX_CLK_PHASE_SEL=0` 回退验证（排除移相引入的新问题；注意字节流曾经 SEL=0 时"有活动但 MAC 全丢"，两态现象不同）
- 主板 ETHB 直发替代 PC（排除 PC 协议栈差异——但 PC 路径已实测干净，优先级低）

**③⑤ RTL 联合仿真已完成（2026-10-09，ModelSim SE 2020.4）**

用 `tools/sim/` 下的自制环境（Python 生成线上帧向量 + tb_cvp_net2vid.v 注入 GMII
→ rgmii_cdc → uiudp_stack → cvp_rx_assemble 全链路, 光栅逐字节比对）跑通 8 个场景
（完整/丢包/整帧丢/重复/乱序/坏FCS/大缺口/心跳, `bash run_sim.sh` 一键复跑）,
结果 **8/8 PASS**, 并定位修复了 4 个重组器 RTL bug（全部是"MAC 通了之后才暴露"的地雷）：

1. `w_desc_free` 未写位宽（默认 1bit，8-0 截断为 0）→ `w_desc_enough` 恒 0，**重组器一个包都收不进**；
2. 应用头判定采样错拍：`w_hdr_last`(bcnt==5) 当拍 r_hdr 只有 5 字节，offset 未对齐 → `w_accept` 比
   决策沿晚一拍 → 永不接受。改为当拍 `{r_hdr[39:0], i_udp_data}` 组合拼接；
3. 描述符队列读写寻址用 `wr[1:0]/rd[1:0]`（模 4）而指针是 3bit（模 8）→ 帧尾描述符周期性丢失，
   **永无 FS**（心跳证据：pushed 冲破 14400 回绕、fcnt 恒 0）。改为全指针寻址；
4. 帧尾标志位按 `BYTE_W` 拼接而读侧固定 `[22]`：真实板 BYTE_W=22 恰好工作，**任何小分辨率参数化
   即复现 FS 丢失**。改为 `DESC_W-1` 显式定位。

另确认并修复 `uimac_rx` 的 lenbad 调试窗口：合法帧 IP 长度=1474B（20+8+1446），
原窗口 [1480,1510] 把所有好帧误判（**交接文档此前"帧长也乱"的结论是该计数器误导**，实为红鲱鱼）。

已知缺口（记录不修）：MAC 对 CRC 错帧仍向上转发载荷（`uiip_arp_rx` 无错误输入端口），
与 PC 端"内核丢坏帧"行为不同；点对点链路 FCS 恒正确，实际无影响。仿真中曾尝试
"len-FIFO 带 CRC 结果位 + 读侧弹空不转发"的加固，因与 FIFO show-ahead 在排空-重填
边界存在字节级交互问题而回退，留作后续工作。

**④b 板级实测更新（LED 判读=LED2常亮/LED3闪 + HDMI 有动态真实内容细条）**：
**CRC 已通过**（crc_ok 累加、crc_bad[10] 恒 0），且 **CLKC1_CPHASE 仍为 5 未扫过**——
即此前"100% CRC 错"的根因不是采样相位，而是旧 bit 的其他缺陷；头号嫌疑是 timing.sdc
的 ARP false_path 修正在本次重编译才首次上板（交接时"已修未验证"），次嫌疑是重新
布局布线改变了 clk1 内部走线延迟。结论：**CPHASE=5 可工作，盲扫作废，保持不动**。
遗留新问题：HDMI 每帧只有几条真实内容细条（内容随光照变化=数据确实到了 DDR），
定位手段见 LED 二阶段改绑（LED2=重组器完成帧 / LED3=FDMA 写活动）。

**④c 全分辨率仿真复现并修复板上"横断带"（同日再追加）**：把仿真升到真机工况
（1280×720、1920 包/帧、背靠背仅 12B IFG、满线速 ~96% 利用率，`gen_real.py` +
`tb_rgmii_ddr_full.v`），**复现板上症状**：帧长完美（921600px/CRC 全过）但内容
大面积为黑。根因是重组器的**丢包-填充极限环**：一次丢包 → 帧尾填充需发 92 万个
黑像素（7.4ms）→ 填充期 staging 无法排空、水位恒超限 → 期间到达的包全部被拒 →
committed 停滞 → gap 级联继续拒 → 下一帧只剩 p0/p1 → 再触发整帧尾填充 → 循环。
每帧只剩开头 960px 真实内容 = 板上"几个细条随光照变化"。
**修复（track-and-drop，通用形式）**：通过格式/界内/顺序检查但被水位挡住的包，
不再直接拒收，而是**推进 committed、不入队**（黑像素由填充覆盖）。这样填充期
间 committed 始终跟随流，填充结束即重新同步，损失只限丢包发生的那一帧。
验证：小套件（480×10, 8 场景）8/8；全分辨率真机工况长跑（**10 帧背靠背**，
`fullres_10f.log`）11/11——上电后 [boot黑、热身残影、seq0半帧] 三帧瞬态后，
seq1..seq8 **连续 8 帧逐像素零失配**、CRC 19201/0（约 256ms/≈8 个 30fps 帧周期
的持续流，无漂移、无周期性劣化）。板上对应操作：用本修复后的 RTL 重编副板
即可，上电头 1-2 帧仍会是部分黑（瞬态，预期行为），之后应出完整连续画面。

**④d 跳动行/撕裂修复 —— uidbuf 双 CDC 裸采（板级实测驱动）**：横断带修复上板后
画面大部分像素正常但偶发撕裂+跳动行。检查 phy 时序报告发现 ddr 域 2 条 -0.884ns
违例的真实身份是**跨时钟域裸采**：uidbuf 写侧 `W_REQ` 直接接 f2d FIFO 的
`afull_flag`（写域 clk_125 信号）被 ui_clk(150M) 状态机采样；读侧 `R_REQ` 直接接
d2f FIFO 的 `aempty_flag`（读域 pclkx1 75M）被 150M 采样（150/75 边沿对齐使 STA
漏报，物理上两颗独立 PLL 漂移下仍会错采）。错采后果与症状一一对应：写侧突发请求
错拍 → 该拍陈旧数据写入 DDR = 跳动行；读侧预取错拍 → 显示段取到陈旧数据 = 撕裂。
**修复**：W_REQ/R_REQ 各加两级同步器（uidbuf.v，阈值余量论证：AF/AE=511 字，
同步延迟 2 拍 ≈13ns ≪ 511 字 ≈4~7µs 余量，无害）；timing.sdc 增补两条
set_clock_groups（125M↔ddr_pll、ddr_pll↔hdmi_pll，同 PLL 输出互为同步归同组）。
重编后 ddr 域违例应清零（ARP 死逻辑违例按既定决定保留不管）。

**补充：W 通路专项仿真（`tools/sim/tb_wpath.v` + 假想 FDMA 写控制器 + 功能级
FIFO 模型 `eg_logic_fifo_sim.v`）**——注意 TD5.6 sim_release 里的 eg_logic_fifo.v
是**空壳模型**（"TO BE FILLED"，标志恒 X，仿真必死），已用功能级替代模型覆盖
（编入 lib_ddr）。30 帧连续满速率压力测试：连续出帧、零过读、零饥饿——**uidbuf
写通路 + W_REQ 同步器在逻辑层无冻结问题**。期间修复了 TB 自身两处 bug（像素源
帧保护条件丢失导致只发 1 帧；`wait;` 非法语法）。板上冻结的最大剩余嫌疑：
**上一版 bit 的畸形 SDC**（`set_clock_groups` 空 group，TD 执行了
`set_clock_groups -asynchronous -group  -group `）——当前 SDC 已改为单时钟/group
的正确写法，重编即可消除该变量。若重编后仍冻结，下一排查对象是 DDR 控制器
(uieg4d_dram) 读写仲裁与 uiphyrst 复位时序（仿真需再挂 DDR 模型）。

**⑤ DDR 层仿真也已打通（同日追加）**：`tools/sim/run_ddr_sim.sh` 从 **RGMII 引脚级**
（4bit DDR behavioral PHY，数据随 RXC 沿翻转 = 无延迟 strap 模式）注入，经
rgmii_interface（行为级 PLL2：clk1=RXC 滞后 2ns 采样 + 安路 EG_LOGIC_IDDR 库模型 +
字节拼装）→ CDC → 协议栈 → 重组器全链路，**同样 8/8 通过**。即：从 RGMII 引脚到
像素的**全部数字逻辑**已被证明正确；需要安路仿真库
（TD5.6 sim_release/eg 全量 + common/al_phy_glbl.v，注意 glbl 实例名必须叫 glbl；
厂商 EG_PHY_PLL 模型不出时钟，仿真用 tools/sim/pll2_sim.v 行为替代——clk1=RXC 滞后 2ns）。

**对板级调试的推论**：RTL 逻辑层已证明正确（CRC 仿真 100% 通过、像素逐字节一致），
当前板上"MAC CRC 全错"必为物理/时序问题（RGMII 采样相位、PLL2 同源跨域），
按 ②③ 的 ChipWatcher 步骤继续即可；MAC 修通后重组器不会再挡路。

**④ 我的怀疑排序（供参考）**
1. `rgmii_cdc` 的 rx_data_fifo/rx_len_fifo 写侧现在跑在 clk1（PLL2 移相输出）——**这套 CDC 的 gray 指针跨 clk1→clk_125**，虽然声明了异步，但 clk0/clk1 同源不同相，2-FF 同步器对 2ns 相位差的 related-clock 可能不干净（TD 对同 PLL 输出默认按 related 分析，我们 set_clock_groups 强行免了）→ 可试：rgmii_cdc 写侧改回 clk0 域（即 rgmii_interface 的 gmii_rxd 寄存输出改回 clk0，仅 IDDR 用 clk1 采样——**IDDR 之后先用 clk0 打一拍再出模块**，让模块内全是 clk0 域，这是最标准的 RGMII 结构）
2. MAC 内部 4 级流水(mac_rdata_r1..r4) 与 crc 判定在帧尾的边界（例程带病点，但 demo 能跑）
3. PHY RXC 本身抖动/占空比差（YT8531 无延迟 strap），2ns 移相落在眼图边缘而非中心 → 试 CPHASE 9

## 6. 文件清单（HDMI_OUT/）

```
HDMI_OUT.al                 TD 工程(EG4D20EG176, 顶层 cvp_hdmi_top, 含 ADC/SDC/VHDL 条目)
build_check.tcl             CLI 编译脚本
README_集成步骤.md
doc/架构文档_网口收流HDMI输出.md   全架构+带宽/资源预算
doc/handoff_*.md            本文
tools/eth_bar_tx.py         PC 发包分诊工具(--fps --gap --ip --port)
uisrc/01_rtl/cvp_hdmi_top.v       顶层(时钟×4PLL/协议栈/重组器/三缓冲/HDMI/LED分诊)
uisrc/01_rtl/cvp_rx_assemble.v    自研: UDP载荷→光栅流(补黑/满帧不变量/FS拉宽)
uisrc/01_rtl/rgmii_cdc.v          例程原件(未改)
uisrc/03_ip/uiudp_stack/          27文件, 改3处: uimac_rx(广播放行+计数器)/
                                  uimac_layer(reset笔误+透传)/uiudp_stack(透传)
uisrc/03_ip/al_pll/PLL2.v         clk1 CPHASE=5 + BUFG
uisrc/03_ip/al_softfifo/udp_pkg_buf.v   full侧指针寄存(v2)
uisrc/03_ip/shiftram|uiphyrst|uifdmadbuf|uisetvbuf|uiappfdma|uieg4d_dram|al_ip|vtc|al_ui_hdmi_tx(HDL)
uisrc/04_pin/pin.adc              全部引脚(LED=P91/104/109/112)
uisrc/04_pin/timing.sdc           时钟+async+false_path(ARP -hierarchical版)
```

主板侧：`08_csi_dsi_cs500_7cun/design_top_wrapper.v`(ETHB 镜像 assign 在文件末尾) + `pin.adc`(ETHB 7 引脚)，TD6.2.1 编译，bit 已烧(22:19)。

## 7. 快速上下文恢复清单

1. 确认发包脚本在跑：`Get-NetAdapterStatistics` 看"以太网"SentBytes 增速（~1.5MB/s@gap8）
2. 确认 PC 网卡 IP=192.168.1.66、ARP 表有 02-1A-2B-3C-4D-5F 静态项
3. 当前板上 bit：GEN_TESTPAT=0 + LED2=lenbad
4. 从证据 #7 继续：单帧内部内容错位，帧头 12B 正确
