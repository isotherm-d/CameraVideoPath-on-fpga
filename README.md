# CameraVideoPath-on-fpga

安路 FPGA 双板实时视频系统。主板把相机图像编码为 UDP 千兆以太网流，子板接收后在本地重组、缓存并输出 HDMI 显示；上位机 Python GUI 同时完成收图与曝光/白平衡控制。

当前版本：**v38 候选**（主板相机工程，PID 6/3/1）+ **v28**（HDMI_OUT 子板回显工程）。v38 已完成仿真、综合和布线，尚待上板验证；历史版本的板测结论不作为 v38 的板测结论。

当前主板源码为 [v38 PID 6/3/1 候选](releases/v38-candidate/README.md)：Q10 系数 Kp=6、Ki=3、Kd=1，曝光优先、达到上限后使用 FPGA 数字增益。大误差用两帧平均、接近目标用四帧平均；仅数字增益变化取消两帧等待，传感器曝光变化保留两帧生效保护。保留高光保护目标、传感器成组提交、短帧残尾丢弃及原生 CSI 帧起点修复。

主板本地 DDR→DSI 支路自 v30 起已裁掉，7 寸屏背光关闭；ETHA 向 PC 发流，ETHB 镜像到 HDMI_OUT 子板。v30 裁剪阶段的 Slice 从 70.73% 降到 49.60%、PLL 从 4 降到 2，该阶段用户已反馈上板功能无误。v38 加入后续流修复和 PID 后的资源结果见下表。[裁剪说明](08_csi_dsi_cs500_7cun/V30网络输出与DSI裁剪说明.md)

## 系统拓扑

```
 SC500CS MIPI          自研 ISP/分类            千兆 UDP                 RGMII 点对点
┌──────────┐   ┌─────────────────────┐   ┌──────────────┐   ┌─────────────────────┐
│  主板    │   │  08_csi_dsi_cs500_7cun │   │ ETHA → PC    │   │  子板 HDMI_OUT       │
│ PH1P35   ├──►│  相机 + ISP 工程(v38)  ├──►│ ETHB ────────┼──►│  EG4D20 (MLKPAI-F01)│
│ MLKPAI-F02│  │                     │   │  (镜像TX)     │   │  → HDMI 720p60      │
└──────────┘   └─────────────────────┘   └──────────────┘   └─────────────────────┘
```

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `08_csi_dsi_cs500_7cun/` | 主板相机工程（v38 候选）：MIPI 接收、ISP、PID AE、边缘/素描、分类、UDP 发送、上位机脚本 |
| `HDMI_OUT/` | 子板 HDMI 回显工程（v28）：网口收流 → 帧重组 → DDR 三缓冲 → HDMI |
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

## 主板相机工程（v38 候选）

基于 MLKPAI-F02 / PH1P35 和 SC500CS 的 1280×720@30fps 相机图像处理工程。

- [v38 比特流：PID 6/3/1](releases/v38-candidate/camera_network_only_v38_pid631_candidate.bit)
- [v38 发布记录与闭环对比](releases/v38-candidate/README.md)
- [构建清单与 SHA256](releases/v38-candidate/manifest.json)
- [主板工程说明](08_csi_dsi_cs500_7cun/README.md)
- [阈值操作、白平衡与 I2C 说明](08_csi_dsi_cs500_7cun/V27优化与阈值说明.md)
- [统一像素流与分类接口](08_csi_dsi_cs500_7cun/V26开发与接口说明.md)
- [队友挂接示例](08_csi_dsi_cs500_7cun/V26队友挂接示例.md)

### 加载与查看图像

1. 在 TD BitWriter 中选择 PROGRAM_SRAM，加载上面的 v38 比特流；SRAM 配置断电后丢失。
2. 板端 ETHA 接 PC，电脑接收网卡设置为 `192.168.1.100/24`，板端为 `192.168.1.66`。
3. 在 `08_csi_dsi_cs500_7cun/tools/` 双击 `打开收图窗口.bat`，或运行 `python cam_gui_v27.py`。脚本名 v27 表示沿用的协议/GUI 入口，硬件构建号以状态区为准；v38 显示“硬件 v38”。只打开一个收图程序。
4. 视频 UDP 6000、控制 UDP 6001、状态 UDP 6002。AE 默认目标亮度 112，高光保护时目标可降低到 32～112；以状态区实际目标判断收敛。

BitWriter 出现 `PRG-8000 Connect server failed` 时，参考 [本机端口冲突排查记录](08_csi_dsi_cs500_7cun/doc/BitWriter_PRG8000端口冲突_20261013.md)；该记录中的 6555 是本机替代端口示例，不代表所有电脑都需要修改。

### 资源与验证

PH1P35MDG324，Anlogic TD 6.2.168116，100MHz 图像处理时钟，布线后结果：

| 指标 | v38 |
|---|---:|
| Slice | 10944 / 21216（51.58%） |
| LUT6 / FF | 8807 / 11035 |
| ERAM20K / DSP / PLL | 51 / 16 / 2 |
| Setup WNS / Hold WNS | +0.119 ns / +0.020 ns |
| Setup TNS / Hold TNS | 0 / 0 |

[资源报告](releases/v38-candidate/resource_report.txt)、[时序报告](releases/v38-candidate/timing_report.txt)。42 项 RTL、两组网络包完整性校验和 38 项 Python 测试通过；视频 RTL 链路模型运行 460 帧，帧序/长度和非黑输出检查通过。闭环模型中 6/3/1 对亮场及暗转亮更快，暗场相同，极暗场略慢；仿真结果不替代实机验证。

### 构建与回归

TD 6.2.168116 打开 `08_csi_dsi_cs500_7cun/td_project/camera_to_dsi_display.al`，顶层为 `design_top_wrapper`，器件为 `PH1P35MDG324`。运行综合、布局布线及比特流生成。`camera_to_dsi_display_Runs/` 是可重建的本地产物，GitHub 提供的候选比特流和验证报告在 `releases/v38-candidate/`。

在主板工程目录运行（ModelSim/TD 安装在其他路径时通过脚本参数指定）：

```powershell
.\tools\run_v29_regression.ps1 -OutputDir "$env:TEMP\cvp_v38_regression" -Python python -ModelSimDir 'C:\modeltech64_2020.4\win64' -TdRoot 'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116'
```

`run_v29_regression.ps1` 是延续到 v38 的回归入口，包含冻结历史实现的差分测试与当前 AE 闭环/完整视频链路测试。Python 测试在 `tools/` 目录运行：

```powershell
python -m unittest test_v26_protocol test_v26_client test_gui_commands test_camera_tools test_v27_quality
```

## 版本历史

- **v38 候选**：PID 默认 Q10 系数改为 6/3/1，启用滤波测量微分；仿真和布线通过，尚待上板。
- **v37 候选**：大误差两帧平均、接近目标四帧平均；纯 FPGA 数字增益取消两帧等待。
- **v36 候选**：短帧残尾丢弃和真实包帧号/偏移、原生 CSI 起点、AE 高光保护目标、SC500CS group hold 成组提交。
- **v35 候选**：PID 算术路径分段，改善时序；历史 v34/v35 差分测试保留。
- **v34 候选**：曝光优先的固定点 PID，曝光到上限后使用 1～4 倍 FPGA 数字增益。
- **v33 候选**：瞬态流错误后连续两帧健康输入恢复显示，增加 RAW/输出长度诊断。
- **v32 候选**：多帧平均及曝光小步调节；其黑屏问题由 v33 修复，保留该版本用于追溯。
- **v31 候选**：卡通中值、对比度及相关流水资源优化。
- **v30**：裁掉主板本地 DDR/DSI 支路，关闭背光，保留 ETHB 镜像；该阶段上板功能验证通过。
- **v29**：主板相机工程资源优化：直方图 LUTRAM 化、状态跨域链 3×1536bit 寄存器改 ERAM 快照桥、元数据 FIFO 寄存器化、数据通路摘异步复位、移除 UART 诊断链（UDP 状态包覆盖）；Slice 81.8%→70.7%、FF -23%，功能与接口不变。
- **v28**：新增子板 HDMI_OUT 实时回显工程（本仓库第二块板卡）；帧重组器多项修复（缺口白名单、跟踪-丢弃、描述符队列、位宽截断）；全分辨率逐字节仿真回归体系（真机工况 11 帧 + DDR 仲裁压力扫描 + OSD 落点账本）。
- **v27**：边缘/素描独立阈值、AWB 优化、摄像头启动重试与分类 I2C 诊断。
