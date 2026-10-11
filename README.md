# CameraVideoPath-on-fpga

安路 FPGA 双板实时视频系统。主板把相机图像编码为 UDP 千兆以太网流，子板接收后在本地重组、缓存并输出 HDMI 显示；上位机 Python GUI 同时完成收图与曝光/白平衡控制。

当前版本：**v28**（子板 HDMI_OUT 实时回显工程）+ **v29**（主板相机工程资源优化版，功能与接口不变）。

## 系统拓扑

```
 SC500CS MIPI          自研 ISP/分类            千兆 UDP                 RGMII 点对点
┌──────────┐   ┌─────────────────────┐   ┌──────────────┐   ┌─────────────────────┐
│  主板    │   │  08_csi_dsi_cs500_7cun │   │ ETHA → PC    │   │  子板 HDMI_OUT       │
│ PH1P35   ├──►│  相机 + ISP 工程(v27)  ├──►│ ETHB ────────┼──►│  EG4D20 (MLKPAI-F01)│
│ MLKPAI-F02│  │                     │   │  (镜像TX)     │   │  → HDMI 720p60      │
└──────────┘   └─────────────────────┘   └──────────────┘   └─────────────────────┘
```

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `08_csi_dsi_cs500_7cun/` | 主板相机工程（v27）：MIPI 接收、ISP、边缘/素描、分类、UDP 发送、上位机脚本 |
| `HDMI_OUT/` | 子板 HDMI 回显工程（本版本新增）：网口收流 → 帧重组 → DDR 三缓冲 → HDMI |
| `releases/` | 各版本比特流与发布记录 |
| `HDMI_OUT/tools/sim/` | ModelSim 全链路仿真环境（Python 向量注入 + 记分板回归） |

## HDMI_OUT 子板工程（v28 新增）

1280×720@60Hz HDMI 实时回显主板 30fps 视频流。

数据通路：RGMII(PLL2 采样 + IDDR) → rgmii_cdc 异步 FIFO → MAC/IP/UDP 协议栈 → `cvp_rx_assemble` 帧重组器（应用头解析、缺口白名单、跟踪-丢弃、描述符队列）→ `uidbuf` 三缓冲 + FDMA → DDR1 → VTC → 安路 logo OSD 叠加 → TMDS 编码 + LVDS 串化输出。

### 关键设计点

- **时钟结构**：PLL2 CPHASE 控制 RGMII 采样相位；ddr_pll / hdmi_pll 异步域在 SDC 中显式声明时钟组。
- **帧重组**：UDP 包 6 字节应用头携带偏移量，缺口 ≤4 包白名单放行并冻结延展填充；更大缺口跟踪-丢弃直到下一帧头。
- **三缓冲**：写 30fps / 读 60Hz 异步，场头锁存切换缓冲；AE 预取水位 1023。事务级 DDR 仲裁仿真（含 2ms 总线黑窗注入）验证显示通路鲁棒。
- **OSD**：右上角安路 logo，16384×9 EBR 位图 + $readmemh 初始化 + 125 色调色板，落点账本仿真逐像素 diff=0。

### 构建（安路 TD 5.6.59063）

1. TD 打开 `HDMI_OUT/HDMI_OUT.al`（EG4D20EG176）。
2. 综合 + 布局布线 + 输出比特流；参考时序约束 `HDMI_OUT/uisrc/04_pin/timing.sdc`。
3. PROGRAM_SRAM 加载 `HDMI_OUT.bit`。

资源占用（门级报告）：LUT 7556/19600（38.9%）、BRAM 44/64、PLL 4/4。

### 仿真（ModelSim 2020.4）

`HDMI_OUT/tools/sim/` 提供三类回归：

| 入口 | 覆盖 |
| --- | --- |
| `run_sim.sh` | 小分辨率协议/重组场景（8 场景记分板） |
| `run_ddr_sim.sh` + `stim_real.hex` | 全分辨率真机工况（1920 包/帧 × 11 帧，逐字节比对） |
| `tb_tear.v` / `tb_osd.v` | DDR 仲裁+刷新压力扫描、OSD 落点账本 |

向量由 `gen_real.py`/`make_vectors.py` 生成（含 CRC 正确的 RGMII 线上字节流）。

### 已知状态

- 上板 HDMI 显示正常，logo 正常；偶发丢包引起的画面闪烁已由冻结延展填充缓解。
- 偶发丢包根因为 RGMII 采样相位随电源状态漂移（CRC 偶发全错），诊断 LED：LED2=crc_bad、LED3=crc_ok；可用 `tools/sim/sweep_cphase.sh` 配合盲扫 CPHASE 求稳定采样点。
- 详细调试交接见 `HDMI_OUT/doc/`。

## 主板相机工程（v29，资源优化版）

基于 MLKPAI-F02 / PH1P35 和 SC500CS 的 1280×720@30fps 相机图像处理工程。

- [v29 比特流](releases/v29/camera_to_dsi_display_v29.bit)
- [发布记录、资源与优化明细](releases/v29/README.md)
- [阈值操作、白平衡与 I2C 说明](08_csi_dsi_cs500_7cun/V27优化与阈值说明.md)
- [统一像素流与分类接口](08_csi_dsi_cs500_7cun/V26开发与接口说明.md)
- [队友挂接示例](08_csi_dsi_cs500_7cun/V26队友挂接示例.md)

TD 选择 PROGRAM_SRAM 加载 v29，比特流断电后丢失。电脑网卡为 192.168.1.100/24，连接板端网口后双击工程 `tools/打开收图窗口.bat`（脚本自动检测并修正本机 IP）。收图 UDP6000、控制 UDP6001、状态 UDP6002，只打开一个收图程序。

v29 验收摘要：22 项 RTL 回归全部通过（含 4 项新旧实现逐位差分对照）；资源优化后 Slice 15006/21216（**70.7%**，v27 为 81.8%）、FF -23%、ERAM 65、布线 setup WNS 0.102ns、hold WNS 0.020ns、TNS 0。功能与接口不变，唯一变化是串口诊断行取消（由 UDP 状态包覆盖）；300s 压力轮换与两光源/Flash 冷启动专项未重跑，状态同 v27。详见 [releases/v29/README.md](releases/v29/README.md)。

## 版本历史

- **v29**：主板相机工程资源优化：直方图 LUTRAM 化、状态跨域链 3×1536bit 寄存器改 ERAM 快照桥、元数据 FIFO 寄存器化、数据通路摘异步复位、移除 UART 诊断链（UDP 状态包覆盖）；Slice 81.8%→70.7%、FF -23%，功能与接口不变。
- **v28**：新增子板 HDMI_OUT 实时回显工程（本仓库第二块板卡）；帧重组器多项修复（缺口白名单、跟踪-丢弃、描述符队列、位宽截断）；全分辨率逐字节仿真回归体系（真机工况 11 帧 + DDR 仲裁压力扫描 + OSD 落点账本）。
- **v27**：边缘/素描独立阈值、AWB 优化、摄像头启动重试与分类 I2C 诊断。
