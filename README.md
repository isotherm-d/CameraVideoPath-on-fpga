# camera processing unit

主板工程入口为 `hardware/mainboard/td_project/camera_to_dsi_display.al`；完整资料见[文档目录](docs/README.md)。发布文件校验：`python tools/check_project_layout.py --published`；不加参数则同时检查本地缓存与私有训练资产是否齐全。

本次版本：[v2026.10.21](https://github.com/isotherm-d/CameraVideoPath-on-fpga/releases/tag/v2026.10.21)，统一主板、HDMI 子板、训练与文档目录，并更新 [24 页作品报告](docs/competition/作品报告.pdf)及[可编译 LaTeX 包](docs/competition/作品报告_LaTeX.zip)。机械结构说明依据显微镜摄像头支架 V10 设计；本次整理不改变当前模型和候选 bit。

若以后移动整个文件夹，先运行 `python tools/configure_project_paths.py` 同步 TD 的本机路径与 HDMI logo ROM 路径。

## 当前主板识别版本

主工程采用 **WBCAtt+ + BCCD 联合训练的 FPGA YOLO-style 检测与五分类**，模型 `wbc_bccd160_devcam_20261021`。最终候选 bit：[camera_to_dsi_display.bit](hardware/mainboard/reports/yolo_wbc_bccd15/current/physical/camera_to_dsi_display.bit)，SHA-256 `5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58`。

720p 全帧图像在 FPGA 内以 15 Hz 运行检测与分类，视频输出保持 30 fps；最多显示一个细胞框，在框左上角标出英文全称，跳过推理的帧沿用上一结果，短漏检也会暂时保留。识别、后处理、框选、文字叠加均在主板完成，PC 和 HDMI 接收的都是板端叠加结果。模型是面向本板实现的 YOLO-style 检测器，不是完整移植的 Ultralytics YOLO。

物理实现使用 19016/21216 Slice、94/108 ERAM、35/40 DSP，setup/hold WNS 为 +0.102/+0.020 ns。WBCAtt+ 已使用 TEST 联合 macro-F1 为 91.40%；该 TEST 曾在前期实验中使用，结果不是独立盲测。两组程序化空场景误检分别为 1.76% 与 0.78%，原 1% 门槛未通过，当前仅作为工程试验版记录。阈值使用过开发图校准，详见[两来源技术报告](docs/reports/README_1021_WBCAtt与BCCD两来源重训.md)及[部署验证记录](hardware/mainboard/reports/yolo_wbc_bccd15/README.md)。

用户反馈实拍效果较前版更好，并表示已自行完成 Flash 烧录；本机 TD6.2 的 Flash 操作未通过 TDO 读回校验，手动烧录使用的文件哈希及冷启动未由本机独立核实，记录见 `hardware/mainboard/reports/yolo_wbc_bccd15/programming_flash_20261021/`。SRAM 构建与候选 bit 的资源、时序和哈希记录保留在本仓库。

CellNet32、中心640/固定480分类及单 WBCAtt 模型是更早的原型实验，不属于当前主工程；本次发布以 WBCAtt+ 与 BCCD 联合训练及活动硬件树为准。`yolo/five/` 中保留的共享模块供部分训练脚本复用。

主板本地 DDR→DSI 支路自 v30 起已裁掉，7 寸屏背光关闭；ETHA 向 PC 发流，ETHB 镜像到 HDMI_OUT 子板。v30 裁剪阶段的 Slice 从 70.73% 降到 49.60%、PLL 从 4 降到 2，该阶段用户已反馈上板功能无误。v38 加入后续流修复和 PID 后的资源结果见下表。[裁剪说明](docs/mainboard/V30网络输出与DSI裁剪说明.md)

## 系统拓扑

```
 SC500CS MIPI        ISP + FPGA YOLO识别/叠加       千兆 UDP                 RGMII 点对点
┌──────────┐   ┌─────────────────────┐   ┌──────────────┐   ┌─────────────────────┐
│  主板    │   │  hardware/mainboard  │   │ ETHA → PC    │   │  子板 HDMI_OUT       │
│ PH1P35   ├──►│  相机 + ISP + YOLO     ├──►│ ETHB ────────┼──►│  EG4D20 (MLKPAI-F01)│
│ MLKPAI-F02│  │                     │   │  (镜像TX)     │   │  → HDMI 720p60      │
└──────────┘   └─────────────────────┘   └──────────────┘   └─────────────────────┘
```

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `hardware/mainboard/td_project/` | PH1P35 主板 TD 工程文件（`.al`、约束）；可重建输出目录不纳入源码整理 |
| `hardware/mainboard/user_source/hdl_source/` | 主板 RTL：相机接口、ISP、YOLO 检测/分类/叠加及网络发送 |
| `hardware/mainboard/tools/` | 板端工程的构建、仿真和诊断脚本 |
| `hardware/mainboard/reports/` | 与 bit、源码哈希、测试摘要和实板记录绑定的报告 |
| `hardware/hdmi/` | 子板 HDMI 回显工程（v28）：网口收流 → 帧重组 → DDR 三缓冲 → HDMI |
| `yolo/wbc_bccd/` | WBCAtt+ 与 BCCD 训练、导出、测试和冻结模型 |
| `yolo/five/`、`yolo/robust/` | 当前训练/校准流程复用的共享代码 |
| `docs/` | 当前技术报告与项目说明 |
| `docs/competition/` | 比赛官方格式 LaTeX 源文档、Word 模板及最新 PDF |
| `docs/design_notes/` | 相机、ISP、命令通路、HDMI 与细胞检测专题文档 |
| `old/releases/` | 历史版本位流、资源报告和发布记录 |
| `old/cellnet32/` | 已退役 CellNet32 分类器及权重；仍被主工程引用的兼容跟踪/标签 RTL 保留在主板源码目录 |
| `hardware/hdmi/tools/sim/` | ModelSim 全链路仿真环境（Python 向量注入 + 记分板回归） |

## HDMI_OUT 子板工程（v28 新增）

1280×720@60Hz HDMI 实时回显主板 30fps 视频流。

数据通路：RGMII(PLL2 采样 + IDDR) → rgmii_cdc 异步 FIFO → MAC/IP/UDP 协议栈 → `cvp_rx_assemble` 帧重组器（应用头解析、缺口白名单、跟踪-丢弃、描述符队列）→ `uidbuf` 三缓冲 + FDMA → DDR1 → VTC → 安路 logo OSD 叠加 → TMDS 编码 + LVDS 串化输出。

### 关键设计点

- **时钟结构**：PLL2 CPHASE 控制 RGMII 采样相位；ddr_pll / hdmi_pll 异步域在 SDC 中显式声明时钟组。
- **帧重组**：UDP 包 6 字节应用头携带偏移量，缺口 ≤4 包白名单放行并冻结延展填充；更大缺口跟踪-丢弃直到下一帧头。
- **三缓冲**：写 30fps / 读 60Hz 异步，场头锁存切换缓冲；AE 预取水位 1023。事务级 DDR 仲裁仿真（含 2ms 总线黑窗注入）验证显示通路鲁棒。
- **OSD**：右上角安路 logo，16384×9 EBR 位图 + $readmemh 初始化 + 125 色调色板，落点账本仿真逐像素 diff=0。

### 构建（安路 TD 5.6.59063）

1. TD 打开 `hardware/hdmi/HDMI_OUT.al`（EG4D20EG176）。
2. 综合 + 布局布线 + 输出比特流；参考时序约束 `hardware/hdmi/uisrc/04_pin/timing.sdc`。
3. PROGRAM_SRAM 加载 `HDMI_OUT.bit`。

资源占用（门级报告）：LUT 7556/19600（38.9%）、BRAM 44/64、PLL 4/4。

### 仿真（ModelSim 2020.4）

`hardware/hdmi/tools/sim/` 提供三类回归：

| 入口 | 覆盖 |
| --- | --- |
| `run_sim.sh` | 小分辨率协议/重组场景（8 场景记分板） |
| `run_ddr_sim.sh` + `stim_real.hex` | 全分辨率真机工况（1920 包/帧 × 11 帧，逐字节比对） |
| `tb_tear.v` / `tb_osd.v` | DDR 仲裁+刷新压力扫描、OSD 落点账本 |

向量由 `gen_real.py`/`make_vectors.py` 生成（含 CRC 正确的 RGMII 线上字节流）。

### 已知状态

- 上板 HDMI 显示正常，logo 正常；偶发丢包引起的画面闪烁已由冻结延展填充缓解。
- 偶发丢包根因为 RGMII 采样相位随电源状态漂移（CRC 偶发全错），诊断 LED：LED2=crc_bad、LED3=crc_ok；可用 `tools/sim/sweep_cphase.sh` 配合盲扫 CPHASE 求稳定采样点。
- 详细调试交接见 `hardware/hdmi/doc/`。

## 主板相机工程（当前：WBCAtt+ + BCCD）

- 最终候选 bit：[camera_to_dsi_display.bit](hardware/mainboard/reports/yolo_wbc_bccd15/current/physical/camera_to_dsi_display.bit)
- 主工程：[TD 6.2 项目文件](hardware/mainboard/td_project/camera_to_dsi_display.al)
- 模型、训练和复现说明：[yolo/wbc_bccd/README.md](yolo/wbc_bccd/README.md)
- 两来源正式技术报告：[docs/README_1021_WBCAtt与BCCD两来源重训.md](docs/reports/README_1021_WBCAtt与BCCD两来源重训.md)
- 完整测试、资源、时序与部署记录：[本轮报告](hardware/mainboard/reports/yolo_wbc_bccd15/README.md)

### 板端行为与资源

主板接收 1280×720 相机帧，在 FPGA 中下采样为 160×160 RGB 输入，每两帧执行一次 YOLO-style 推理。HDMI/PC 视频仍为 30fps，最多保留一个细胞框，标签为 Basophil、Eosinophil、Lymphocyte、Monocyte 或 Neutrophil。非推理帧沿用上一次完整框；短漏检保持两帧，第三次漏检撤框。PC 只收图和下发相机参数，不运行识别或补画算法。

| 指标 | 当前候选实现 |
|---|---:|
| 主板资源 | 19016 / 21216 Slice，94 / 108 ERAM，35 / 40 DSP |
| 时序 | Setup WNS +0.102ns；Hold WNS +0.020ns |
| 视频/推理 | 30fps 视频；15Hz 推理 |
| 显示 | 每帧最多一个框，框左上角显示英文全称 |
| bit SHA-256 | `5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58` |

训练和门槛结果按试验数据解释：WBCAtt+ TEST 联合 macro-F1 为 91.40%，但该测试集曾参与前期实验；程序化空场景两组误检率为 1.76% 和 0.78%，原定 1% 门槛未通过。不能把开发截图校准或程序化场景结果称为独立实拍准确率。

### 构建与回归

在 TD 6.2.168116 中打开 `hardware/mainboard/td_project/camera_to_dsi_display.al`，目标器件为 `PH1P35MDG324`。最终构建的 bit、构建摘要及 203 项源文件哈希清单位于 `hardware/mainboard/reports/yolo_wbc_bccd15/current/physical/`。本地已通过 42 项视频 RTL、2 项包完整性和 38 项 Python 回归；训练数据及含像素的原始向量没有随发布提交。

用户表示已自行把较好版本烧入 Flash。自动 Flash 尝试的 TDO 校验失败仍单独留档；本仓库不把本机失败日志标记为成功，也没有对用户手动烧录的 bit 身份或断电冷启动作独立验证。SRAM 下载记录和用户反馈见 `hardware/mainboard/reports/yolo_wbc_bccd15/`。

## 版本历史

- **2026-10-21 WBCAtt+ + BCCD 主线试验版**：160×160全帧 YOLO-style 检测/五分类，15Hz 推理、单框全称显示；物理时序通过。用户报告实拍较前版更好并已自行烧录 Flash，手动烧录哈希未独立核验；原1%程序化背景误检门槛未通过，详见本轮报告。

- **v38 视频平台基线**：PID 默认 Q10 系数改为 6/3/1，启用滤波测量微分；识别主线已由当前 YOLO-style 版本接管。历史 bit 与报告仍保留在 `old/releases/v38-candidate/`。
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
