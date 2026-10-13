# MLKPAI-F02 相机工程（1280x720@30fps，v38 PID 6/3/1 候选）

SC500CS MIPI 摄像头 → PH1P FPGA 自研 ISP → 千兆网口推流（UDP），
PC 端 GUI 实时观看并网络控制曝光/白平衡。

当前源码为 [v38 PID 6/3/1 候选](../releases/v38-candidate/README.md)：默认 Q10 系数 Kp=6、Ki=3、Kd=1，保留 v37 自适应两/四帧平均及曝光优先。42 项 RTL、两组包校验和 38 项 Python 测试通过，Setup WNS +0.119ns，Slice 10944、ERAM 51、DSP 16。尚待上板验证，历史候选保留。

主板 DDR→DSI 显示支路自 v30 起已裁掉，7 寸屏背光关闭；ETHB 镜像到 HDMI_OUT 子板的显示仍保留。v30 裁剪阶段的布线后 Slice 为 49.60%，用户已反馈该阶段上板功能无误，详见 [V30网络输出与DSI裁剪说明.md](V30网络输出与DSI裁剪说明.md)。当前 v38 为 Slice 51.58%、ERAM 51、DSP 16、PLL 2，尚待上板验证。

- **状态**：v38 的 42 项 RTL、两组网络包校验、38 项 Python 测试及综合布线通过；尚未上板。当前流健康、短帧恢复与高反差 AE 模型验证见候选发布记录。
- **版本说明**：[当前 v38 发布记录](../releases/v38-candidate/README.md)；[v36 流修复与高光保护](../releases/v36-candidate/README.md)；历史 v29 资源优化见 [V29优化说明.md](V29优化说明.md)，v27 阈值/白平衡见 [V27优化与阈值说明.md](V27优化与阈值说明.md)。
- **上位机入口**：`tools/打开收图窗口.bat`。白平衡支持标定预设、色温 K 值、手动 RGB 及自动白平衡；预览和 PNG 均为正确 RGB 顺序。
- **默认参数**：曝光 500 半行，模拟增益 108 档，参考白平衡 R344/G256/B451；PID Q10 系数 6/3/1，数字增益起始 1 倍。6500K 为参考锚点。

## 当前版本操作与验证

加载 [v38 候选比特流](../releases/v38-candidate/camera_network_only_v38_pid631_candidate.bit)，重启收图程序后查看状态区“硬件 v38”和实际 AE 目标。旧版候选与日志保留供追溯，不应把其中的资源数据当作当前构建结果。

AE 优先调曝光（62～1800 半行），达到曝光上限后使用 1～4 倍 FPGA 数字增益，模拟增益保持手动设定。误差绝对值至少 24 时用两帧平均，接近目标时用四帧平均；纯数字增益在 SOF 提交后立即收集新统计，曝光变化和手动提交保留两帧保护。目标默认 112，高光约束触发时可降低至 32～112，死区为实际目标 ±8。

构建入口为 `td_project/camera_to_dsi_display.al`，使用 TD 6.2.168116 / PH1P35MDG324。回归入口为 `tools/run_v29_regression.ps1`，命令及当前资源/时序表见 [仓库 README](../README.md#构建与回归)；报告和 SHA256 清单见 [v38 发布目录](../releases/v38-candidate/README.md)。

---

## 1. 数据通路

```
SC500CS(MIPI 2lane RAW10, 采窗1287x727, 实发1280x720)
  → csi_unpacket/raw10 解包
  → uial2axis (IMG_W=1280, IMG_H=720)          ← 注意 720=实发行数, 727=采窗行数
  → line_retimer (重切 320拍 x 720行)
  → group_fifo (40.2M → 100M 跨时钟域)
  → cvp_proc (齿轮箱 4→1 + DPC 等延迟旁路 + 3x3 双线性 demosaic, BGGR)
  → cvp_advanced (cvp_gain11 白平衡/全局数字增益 → 统计/PID AE → tone/style/OSD)
  → pack_4 (攒 96bit 组, 4像素/组)
  → cvp_eth_dbg (GMII 125M 域字节展开, 1920 包/帧)
  → RGMII → YT8531 PHY → 网线 → PC
                               ↘ cvp_cmd_rx (UDP 6001 命令: 曝光/白平衡)
                               ↘ cvp_advanced/cvp_sensor_bridge → uicfgcs500 → I2C group hold → 传感器

显示: PC 接收 ETHA；HDMI_OUT 子板接收 ETHB 镜像。主板 DDR/DSI 支路已裁掉。
统计支路: v29 起串口诊断链已移除(帧率/健康判定改用 UDP 状态包, 见 V29优化说明.md)
```

## 2. 历史参数（v23 参考值；v25 以 V25校色说明.md 为准）

| 参数 | 值 | 位置 | 说明 |
|---|---|---|---|
| 传感器 VTS | 1003 (0x320e/f=03EB) | `uics500_cfg/uics500reg.v` | 30.0fps 实测校准 |
| 输出分辨率 | 1280x720 | 顶层例化 | 采窗 1287x727 居中于原 1080p 窗 |
| 默认曝光 | 1700 半行 (850 行) | `isp2/cvp_proc.v` AE_EXP_CODE | 合法 62..1800，**禁止更高**（见下） |
| 模拟增益 | 108 档 = 0x0F3C = 7.5x | `isp2/cvp_proc.v` AE_GAIN_IDX | 编译期参数, 档位 16..143 = 1.0x..15.75x |
| 白平衡数字增益 | R438/G386/B371 (Q8) | 顶层 color_correct 例化 | 标定 1.136x × 补光 1.506x |
| 视频流 | UDP 6000, 1440B x 1920 包/帧 | — | 包头 6B: [帧序号, 格式, 偏移(4B 大端)] |
| 命令流 | UDP 6001, 广播 | `net/cvp_cmd_rx.v` | 魔数 C5A55001, 详见使用手册 |

**曝光上限 1800 的原因**：曝光贴近满帧（VTS=1003 行）时，传感器读出窗相对帧同步
偏移数行，720 行窗口的顶部或底部会出现错位带（v23 实测 1940/1980 均复现）。
1800（900 行）留 103 行裕量安全。需更亮优先加增益档或补光，不要加曝光。

## 3. 目录结构

```
08_csi_dsi_cs500_7cun/
├── README.md / 使用手册.md        本文档
├── 交接总结.md / 改动说明_*.md     历史 bug 记录与阶段总结(定版文档的一部分)
├── doc/                           PH1P MIPI D-PHY 等原厂应用笔记
├── td_project/                    TD 工程(.al/.sdc)，_Runs 为本地可重建产物
├── user_source/hdl_source/
│   ├── design_top_wrapper.v       顶层(所有模块例化与参数覆盖都在这)
│   ├── isp2/                      自研 ISP: cvp_proc/dpc/demosaic/color_correct/
│   │                              pack_4/group_fifo/wb_kelvin/imgproc_win3x3
│   │                              (cvp_ae/cvp_awb/ae_mux 已摘除, 保留源文件不编译)
│   ├── advanced/                  cvp_advanced、PID AE、统计、数字增益、风格/OSD、传感器请求桥
│   ├── net/                       网口: cvp_eth_dbg(发流) / cvp_cmd_rx(命令)
│   ├── uics500_cfg/               传感器 I2C 配置: 主表/AE 表/SC500GainTbl 增益表
│   ├── uial2axis/ line_retimer.v  采集行/帧切分
│   ├── ph1p35_ddr/                DDR IP
│   └── (其余为原厂/早期实验模块)   video_*/isp/mipi_dphy_*/uiisp_beta 等
└── tools/                         上位机与诊断工具(见使用手册)
```

## 4. 版本与 bug 修复史（详见各改动说明与 git log）

| 版本 | 修复/变更 |
|---|---|
| **v38 候选** | PID Q10 默认系数 6/3/1；保留曝光优先与自适应两/四帧平均。仿真及布线通过，尚待上板。 |
| **v37 候选** | 大误差两帧平均，接近目标四帧；纯 FPGA 数字增益取消两帧等待。 |
| **v36 候选** | 真实 CSI 帧起点、短帧残尾丢弃及逐包帧号/偏移、AE 高光保护目标、SC500CS 成组提交。 |
| **v34/v35 候选** | 曝光优先的 PID/数字增益分配，随后增加算术流水改善时序。 |
| **v33 候选** | 瞬态流错误后两帧健康输入恢复显示，扩展 RAW/输出帧健康诊断。 |
| **v30/v31** | 裁掉本地 DDR/DSI 支路；随后优化中值、对比度及相关流水资源。 |
| v3 | ae_set 曝光语义错误(24000 半行>>VTS) → 画面黑/帧率乱 |
| v4 | cvp_eth_dbg 每像素 3 拍接口不匹配 → 帧率÷3+斜条纹 |
| v5 | 字节展开放像素域(40.2MHz)超速 → 移到 GMII 域 |
| v7 | pack 双读覆盖 → 吞吐恒减半 |
| v8/v9 | 预取队列丢写（后续被重构取代） |
| v13e | imgproc_win3x3/demosaic 行列计数无帧对齐 → 色平面错位 |
| v17 | 白平衡标定 + 1.506x 数字补光（曝光 49.8→33.1ms 的补偿） |
| v18c | uial2axis IMG_H 参数混淆(727 采窗 vs 720 实发) → 帧头漂移 |
| v21 | 网络命令通路(cvp_cmd_rx + color_correct 运行时增益) |
| v22 | 摘除 cvp_awb/ae_mux/ae_set；20fps 实验（GMII 裕量） |
| v22b | IMG_HEIGHT 727→720 + VTS 恢复 1003（修上下半帧互换，1.7s 漂半帧） |
| **v24** | 摄像头基础配置完成后才发曝光请求；初始化完成后 AE 表索引归零；UDP 命令完整接收三个数值字节；补充启动与 RGMII 接收回归测试。实物验证待完成。 |
| **v23** | **①曝光滑条复活**（cvp_cmd_rx o_exp_wr → cvp_proc 运行时锁存+重写传感器）**②增益表补全**（原表只到 5.125x，按手册补到 15.75x）**③恢复 v17 补光**（v22 重构时误丢 1.5x）**④默认曝光 1700/上限 1800**（修顶/底错位带） |

## 5. 已知限制与注意事项

1. **板测状态**：v38 尚待实机验证，包括 AE 响应、噪声及长时间流稳定性。PC 的
   complete=100% 只说明收到一组包，应同时看 RAW 组数、输出长度和累计流错误。
2. **暗光噪声**：模拟增益保持用户设置（默认 108 档、7.5 倍）；曝光达到 1800 后
   AE 使用 FPGA 数字增益，数字增益也会放大噪声。曝光不超过当前安全上限。
3. **目标亮度**：高光保护可能主动降低目标，均值低于 112 不一定表示尚未收敛。
   PID 6/3/1 是 Q10 编码，不是浮点系数；修改后需要重跑仿真和时序检查。
4. **工程维护**：裁剪后的 `.al` 和 `tools/td_templates/project.prj` 为当前源文件列表，
   新模块需同步注册。保留的历史/原厂模块不表示它们仍参与综合；部分文件为 GBK。
5. **测量纪律**：UDP 抓帧必须独占 6000 端口（关掉 GUI），否则 Windows 分流产生
   假读数（0.8fps / complete=50% 假象）。
