# HDMI_OUT 架构文档：网口接收 PH1P35 视频流并 HDMI 输出

> 工程: `cvp/CameraVideoPath-on-fpga/HDMI_OUT`（TD5.6，EG4D20EG176，MLKPAI-F01 板）
> 角色: 纯接收显示副板。PH1P35 主板 ETHB(镜像 ETHA) → 网线 → 本板 RJ45 → HDMI 显示器
> 无命令通路（曝光/白平衡命令只走主板 ETHA ↔ PC），本板零参数调节。

---

## 1. 系统链路与两端约定

```
┌─ PH1P35 主板 ──────────────────────────────────────────────┐
│ 摄像头 → ISP/AWB → cvp_eth_dbg → cvp_gmii_mac_tx           │
│                    (UDP 打包, 697Mbps 载荷)                 │
│   ETHA(YT8531) ──→ PC(控制+预览)                            │
│   ETHB(YT8531) ──→ 镜像输出口(与 ETHA 完全相同的 RGMII TX)   │
└────────────────────────┬───────────────────────────────────┘
                         │ 千兆直连网线(两颗 YT8531DH-CA 自协商 1000M)
┌─ EG4D 副板(本工程) ─────▼───────────────────────────────────┐
│ RGMII RX → MAC/IP/UDP 解析 → 重组器(丢包补黑) → 三缓冲       │
│   → 合封 DDR1(16MB) → 720p60 时序 → TMDS → HDMI             │
└─────────────────────────────────────────────────────────────┘
```

关键约定（两端必须一致，改一处须同步另一处）：

| 参数 | 值 | 定义处 |
|---|---|---|
| 分辨率/帧率 | 1280×720 RGB888, 30fps 入 / 60fps 显示 | 主板 `cvp_eth_dbg` 参数 |
| 每包载荷 | 1440 B = 480 像素 | 主板 `DATA_BYTES` |
| 每帧包数 | 1920 | 2764800 B / 1440 |
| 源 IP → 目的 IP | 192.168.1.66 → **192.168.1.100** | 主板 `IP_DST`；本板协议栈 `I_ip_local_addr` 必须等于它 |
| 源/目的端口 | 6000/6000（视频）| 状态包走 6002，本板按 fmt 字节丢弃 |
| 目的 MAC | 广播 FF:FF:FF:FF:FF:FF | 本板 MAC 层已放行广播 IP 帧 |

## 2. 线上包格式（读自 `cvp_gmii_mac_tx.v`，PC 脚本 `capture_now.py` 交叉验证）

以太网帧 1500 B：`前导7×55+SFD(D5) | ETH14 | IP20 | UDP8 | 应用头6 | 数据1440 | FCS4`

- ETH：DA=广播，SA=02:1A:2B:3C:4D:5E，Type=0x0800
- IP：proto=0x11(UDP)，校验和有效，无分片
- UDP：sport=dport=6000（状态包 sport=6002），UDP 校验和=0（IPv4 合法）
- **应用头 6B（大端）**：
  - `byte0` frame_seq 帧计数（主板 ENABLE_STATUS=1 时为 frame_id 低 8 位）
  - `byte1` fmt：**0x01=视频**、0x02=心跳(ENABLE_STATUS=0 才有)、0x26=状态(端口6002)
  - `byte2..5` offset：本包数据在整帧字节流中的偏移 = 包序×1440
- 数据区：连续像素字节，每像素 3 字节 **R,G,B**
- 帧率带宽：1920 包 × 12µs ≈ 23.6ms/帧 → 30fps，线速 ~697Mbps（千兆必须）

## 3. 副板架构

```
                     ┌─ clk_125 (pll_gmii, 25M晶振) ──────────────────────────┐
 YT8531 RGMII RX ──→ │ rgmii_interface (PLL2 清洗RXCK + IDDR) [例程UDP]      │
                     │   → rgmii_cdc (RXCK域→125M)            [例程UDP]      │
                     │   → uiudp_stack                         [例程UDP,改1处]│
                     │      MAC(CRC校验/广播IP放行) → IP(目的IP过滤) → UDP    │
                     │   → cvp_rx_assemble ★新写★ (载荷→顺序光栅像素流)      │
                     └──────────┬ W_FS/W_de/W_rgb(24b) ──────────────────────┘
                                │ (uidbuf 内部 W_FIFO 异步跨域)
                     ┌─ fdma_clk 150M (ddr_pll) ─────────────────────────────┐
                     │ uidbuf ★例程25★ 三缓冲控制器 (1280×720×24b×3buf)      │
                     │   W: FS+满帧驱动 FDMA 写 | R: 行预取 FDMA 读           │
                     │ app_fdma [例程25] → ddr1_as_ram [例程25]               │
                     │   → EG_PHY_DDR_8M_16 (合封16MB DDR1, 帧步进4MB)       │
                     │ uisetvbuf [例程25]: 写读缓冲轮换(读落后写1帧)          │
                     └──────────┬ R_data(24b) ────────────────────────────────┘
                                │ (uidbuf 内部 R_FIFO 异步跨域)
                     ┌─ pclkx1 75M (clk_hdmi_pll) ───────────────────────────┐
                     │ uivtc 720p60(1651×757@75M) [例程23] → RGB 对齐寄存    │
                     │   → uihdmitx (TMDS, PCLKX5=375M serdes) [例程23] → HDMI│
                     └────────────────────────────────────────────────────────┘
```

时钟域共 6 个：`clk_125`（协议栈+重组器）、`gmii_rxc/PLL2`（PHY RX，rgmii_cdc 跨出）、`fdma_clk 150M`（DDR1+uidbuf 核心）、`pclkx1 75M`（显示）、`pclkx5 375M`（TMDS 原语内部）、`clk_12_5`（PHY 复位时序）。PLL 占用 4/4：pll_gmii、PLL2、ddr_pll、clk_hdmi_pll（DS302 数据手册确认 EG4D20 共 4 个 PLL）。

## 4. 新写模块说明

### 4.1 `cvp_rx_assemble`（网口载荷 → 光栅视频流）

**解决的问题**：协议栈输出的是"无反压、按包到达顺序"的 UDP 载荷字节流；`uidbuf` 需要的是"每帧恰好 921600 像素、帧同步脉冲分隔"的顺序视频流。两者之间隔着丢包、乱序容忍、30→任意速率整形三道鸿沟。

**算法**（PC 脚本 `capture_now.py` 的硬件化，适配无反压约束）：

1. **输入侧**（每输入字节 1 拍，无反压必达）：解析 6B 应用头 → 判定接受：
   `fmt==0x01` 且 `offset+1440≤帧长` 且（`offset==0`(新帧标记) 或 `offset≥已承诺位置` 且 `缺口∈{0,1,2,3,4}×1440B` 白名单）。缺口白名单归纳保证接受的包恒为 1440B 整包对齐（committed 初值 0、每次接受 committed=offset+1440）。
   接受的包：载荷字节压入 4096B staging FIFO；描述符（目标 offset）入 8 深队列；`offset==0` 的包先额外插入一条**帧尾描述符**。
2. **输出侧**（描述符状态机，严格顺序）：
   - `S_FILL`：从已输出位置补黑像素到本描述符 offset——丢包空洞变黑，空间对齐；
   - `S_DATA`：从 staging 弹 3 字节拼 RGB 输出 480 像素；
   - `S_FS`(帧尾描述符)：补黑到 FRAME_BYTES → 发 `o_w_fs` → 位置清零。
3. **不变量**：任意两个 FS 脉冲之间恰好输出 921600 像素（实像素+补黑）。这保证 uidbuf 写侧 FDMA 状态机每帧固定 burst 数、永不因短帧卡死。
4. **丢包行为**：连丢 ≤4 包 → 无感恢复（黑洞补黑）；连丢 >4 包 → 该帧剩余部分整帧丢弃、尾部补黑，下一帧 offset==0 自动重新同步；码流彻底中断 → 最后一完整帧静止显示。
5. **staging 水位论证**：FILL 期黑 1 像素/拍 vs 输入 1B/拍，峰值 ≈2 包(2.9KB) < 4096B；DATA 期弹 3B/拍 ≥ 入速，迅速回落。

### 4.2 `cvp_hdmi_top`（顶层集成）

- 三条例程链拼接 + 全部时钟/复位生成（PHY 复位时序照抄 UDP 例程，DDR 复位=init_done，HDMI 复位=PLL lock）。
- 协议栈参数：本地 IP=192.168.1.100（匹配流的目的 IP）、本地 MAC 任取、发送侧请求恒 0（纯接收）。
- RGB 对齐：`R_data[23:0]` 与 `vid_de` 同拍打一拍寄存器再送 uihdmitx（DE 同样延迟一拍），保证像素/使能对齐。

### 4.1.1 跟踪-丢弃（水位阻塞时的 committed 推进）

重组器在帧尾/洞填充（最长 74 万拍）期间 staging 无法排空，水位挡住的包若直接
拒收，committed 停滞并引发 gap 级联（后续帧整帧丢失，板上表现为横断带）。修复：
通过格式/界内/顺序检查但被水位挡住的包**推进 committed、不入队**（黑像素由填充
覆盖），填充结束即重新同步，损失只限丢包发生的那一帧。

## 4.3 RTL 仿真验证（2026-10-09）

`tools/sim/` 提供全链路 RTL 仿真（ModelSim）：Python 生成主板线上格式帧（含正确
FCS）注入 GMII，期望光栅逐字节比对，8 场景（完整/丢1包/整帧丢/重复/乱序/坏FCS/
缺6包/心跳）8/8 通过。仿真定位并修复 4 个重组器 bug：w_desc_free 位宽截断、应用头
判定采样错拍（改为当拍组合拼接完整头）、描述符队列模4寻址（指针实为模8）、帧尾
标志位按 BYTE_W 而非 DESC_W-1 定位。复跑：`cd tools/sim && bash run_sim.sh`。
注意 lenbad 调试窗口已同步修正（合法帧 1474B）。已知缺口：坏 FCS 帧载荷仍向上
透传（例程架构限制，点对点链路无实际影响）。

## 5. 复用例程清单与唯一修改点

| 来源例程 | 拷贝内容 | 修改 |
|---|---|---|
| `3_1_02_fpga_udp/02_udp_tri` | `uiudp_stack` 全套 27 文件、`rgmii_cdc.v`、`al_pll/{pll.v,PLL2.v}`、`al_softfifo/udp_pkg_buf.v`、`uiphyrst.v` | **`uimac_rx.v` 广播分支：仅 ARP 放行 → ARP 或 IP 均放行**（视频流 DA=广播）。IP 层仍有目的 IP 精确过滤兜底 |
| `3_1_01_fpga_base/25_cam_ddr_buf` | `uidbuf.v`+`fs_cap.v`、`uisetvbuf.v`、`uiappfdma.v`、`uieg4d_dram` 4 文件、`ddr_pll.v`、`hdmi_pll.v` | 无（参数化例化） |
| `3_1_01_fpga_base/23_rgb2hdmi_output` | `uivtc.v`、`uihdmitx.v`、`clk_hdmi_pll.v` | 无（`uitpg` 测试图案被重组器替换——这正是"转化为例程 HDMI 可接受信号"的接缝） |

## 6. 资源与带宽预算

| 项 | 预算 | 实际 | 余量 |
|---|---|---|---|
| DDR1 带宽(峰值600MB/s) | 写110.6(30fps×3.69MB) + 读221.2(60fps) | 331.8 MB/s = 55% | 顺序突发, 充足 |
| DDR1 容量 16MB | 3缓冲×4.19MB(帧步进2^22) | 12.6 MB | 若降 RGB565 可减半带宽(后备开关: uidbuf W/R_DATAWIDTH=16) |
| PLL | 4 | 4 | 0(满) |
| LUT ~20K | 协议栈~4K+DDR链~3K+HDMI~2K+重组器~1K | ~10K | ~50% |
| EBR 29×18Kb | staging 4K×8b + uidbuf 内部 FIFO ×2 | ~6 块 | 充足 |

## 7. 验证与调试建议

1. **先跑例程确认硬件**：分别烧 02_udp_tri（PC 用它自带的回环工具测网口）和 23_rgb2hdmi_output（彩条上屏），确认网口/HDMI 物理层正常。
2. **分层点亮本设计**：
   - 第一拍：ChipWatcher 看 `udp_rx_valid` 有无翻转（PHY 链路+MAC+IP+UDP 通）；若无，先查 `u_rgmii_if.PLL2` lock 和 YT8531 自协商是否 1000M（100M 下码流带宽不够，必丢）。
   - 第二拍：看 `rx_frame_cnt`（重组器完整帧计数）是否 ~30/s 递增；不动则查 staging/描述符状态机。
   - 第三拍：显示器出图。撕裂=三缓冲轮换问题(查 uisetvbuf)；黑屏但有帧计数=RGB 通道序问题（PH1P35 侧 R/B 未标定，可对调 `R_data[23:16]`/`[7:0]` 试试）。
3. **两端 IP**：PC(ETHA 侧) 与本板不能同为 192.168.1.100；本板是纯二层接收，无 ARP/ICMP 响应，ping 不通属正常。
4. 主板侧 ETHB 镜像已在前一任务完成（`design_top_wrapper.v` + `pin.adc`），两块板共用 `ETH_RST_B(H2)`，主板恒 1 无需改动。

## 8. 已知限制

- 重组器缺口容忍 4 包：>4 包连续丢包整帧作废（30fps 下视觉为一帧闪黑）。
- 帧序号 byte0 未参与重组（纯 offset 定位），与 PC 脚本行为一致。
- 状态包(6002/fmt=0x26)到达协议栈 UDP 层后被重组器按 fmt 丢弃，不占任何资源。
- HDMI 75MHz 是例程的"近似 720p60"（74.25 标准值的 +1%），例程已验证显示器兼容；若有显示器挑时序，需重生成 74.25/371.25 PLL（25M 无法整倍频出 74.25，需换分数 PLL 配置——例程选择 75M 正是绕开此问题）。
