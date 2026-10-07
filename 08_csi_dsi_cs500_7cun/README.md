# MLKPAI-F02 相机工程（1280x720@30fps，v25 校色版本）

SC500CS MIPI 摄像头 → PH1P FPGA 自研 ISP → 千兆网口推流（UDP）+ 7 寸 DSI 屏显示，
PC 端 GUI 实时观看并网络控制曝光/白平衡。

- **状态**：v25 已完成图像标记、Bayer 相位、网口帧边界与白平衡修复，18 项 Python、10 项 RTL 回归及 TD 时序通过；开发板网口出图与颜色控制验证通过。顶部窄边仍待定位。
- **版本说明**：[V25 控件、色温曲线和验证记录](V25校色说明.md)。v24 标签及其比特流保留；此前撤销的画质试验仍在独立备份目录中。
- **上位机入口**：`tools/打开收图窗口.bat`。三种白平衡模式：标定预设、色温 K 值、手动 RGB；预览和 PNG 均为正确 RGB 顺序。
- **默认参数**：曝光500半行，参考白平衡R344/G256/B451；6500K为参考锚点，具体校准范围和限制见版本说明。

---

## 1. 数据通路

```
SC500CS(MIPI 2lane RAW10, 采窗1287x727, 实发1280x720)
  → csi_unpacket/raw10 解包
  → uial2axis (IMG_W=1280, IMG_H=720)          ← 注意 720=实发行数, 727=采窗行数
  → line_retimer (重切 320拍 x 720行)
  → group_fifo (40.2M → 100M 跨时钟域)
  → cvp_proc (齿轮箱 4→1 + DPC 等延迟旁路 + 3x3 双线性 demosaic, BGGR)
  → color_correct (正确 Q8 增益/四舍五入/饱和，三种模式和全模式 R/B 互换)
  → pack_4 (攒 96bit 组, 4像素/组)
  → cvp_eth_dbg (GMII 125M 域字节展开, 1920 包/帧)
  → RGMII → YT8531 PHY → 网线 → PC
                               ↘ cvp_cmd_rx (UDP 6001 命令: 曝光/白平衡)
                               ↘ cvp_proc AE 参数通路 → uicfgcs500 → I2C → 传感器寄存器

显示支路: color_correct 输出 → rgb_frame_crop 居中裁 1024x600 → DSI 7寸屏
统计支路: cam_stats x2 + cam_report_uart → 串口打印 CAM/ISP 帧率与组数
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
├── td_project/                    TD 工程(.al) 与 _Runs/best_result 烧录产物
├── user_source/hdl_source/
│   ├── design_top_wrapper.v       顶层(所有模块例化与参数覆盖都在这)
│   ├── isp2/                      自研 ISP: cvp_proc/dpc/demosaic/color_correct/
│   │                              pack_4/group_fifo/wb_kelvin/imgproc_win3x3
│   │                              (cvp_ae/cvp_awb/ae_mux 已摘除, 保留源文件不编译)
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

1. **GMII 展开器零裕量**：30fps 需求 10.37M 组/s vs 能力 10.42M。实测稳定
   （complete=100%），但若未来偶发丢帧，首选降 24fps（VTS 1280，同时曝光上限
   提到 ~41ms），或展开器 12 拍→10 拍改造。
2. **暗光噪声**：7.5x 模拟增益下暗部噪声可见。更暗环境可将 AE_GAIN_IDX 继续上调
   （112 档=8x … 143 档=15.75x 封顶，改一个参数重编译）；根治靠补光。
3. **K 色温模式无补光**：拖色温滑条时亮度会回落（G 固定 1.0x），属设计取舍。
4. **工程维护**：TD 编译失败后检查 `.al` 的 AutoExcluded 是否新增（当前 4 处
   cvp_ae/cvp_awb/ae_mux/ae_set 为有意排除，勿清理）；新增源文件必须 Add Sources。
   部分原厂文件为 GBK 编码，编辑时注意按 GBK 读写。
5. **测量纪律**：UDP 抓帧必须独占 6000 端口（关掉 GUI），否则 Windows 分流产生
   假读数（0.8fps / complete=50% 假象）。
