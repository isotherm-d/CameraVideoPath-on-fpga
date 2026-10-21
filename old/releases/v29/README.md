# V29 发布 —— 主板工程资源优化(功能与接口不变)

在 v27 功能基线上对主板相机工程(08_csi_dsi_cs500_7cun)做三轮纯资源优化:图像七模式、
AE/AWB、UDP 收图(6000)/控制(6001)/状态(6002)、按键、OSD、标定 R344/G256/B451 与分类
挂接接口全部保留。**唯一的功能变化:串口不再每秒打印 CAM/ISP 两行诊断**(该信息由 UDP
状态包完整覆盖,O_uart_tx 引脚保持常高空闲电平,引脚约束未动)。

## 资源对比(TD 6.2.168116 布线后,同 1280×720@30fps)

| 指标 | v27 | v29 | 变化 |
|---|---|---|---|
| Slice | 17359(81.8%) | **15006(70.7%)** | -2353,-11.1 个百分点 |
| LUT6 | 14455 | 12744 | -1711 |
| 触发器 | 19999 | 15462 | -4537(-22.7%) |
| ERAM20K | 66 | 65 | -1 |
| DSP | 10 | 10 | 0 |
| F7/F8mux | 96/41 | 16/1 | -80/-40 |
| 布线总长 | 4.57M | 3.94M | -13.7% |
| Setup WNS | +0.107ns | +0.102ns | 收敛,TNS=0,hold 无违例 |

## 优化明细

- **A1 直方图 LUTRAM 化**(cvp_frame_stats):32bin×20bit 触发器直方图阵列与 EOF 快照
  阵列改为单端口分布式 RAM,消隐期旋转清扫;走查直读,首帧黑/白点与 AWB 增益行为逐位不变。
- **A2 状态跨域链 ERAM 化**(cvp_eth_dbg/cvp_gmii_mac_tx):原来 mailbox(held+m_data)+
  status_packet 三份 1536bit 寄存器,改为 cvp_status_bridge 双 bank ERAM 快照 + 发送期
  流式读;线上字节序(base 1024 大端在前、扩展区大端在后)与原实现位精确。模块已并入
  cvp_eth_dbg.v 文件尾部以规避 TD 对新增独立文件的 AutoExcluded 反复。
- **A3 元数据 FIFO 瘦身**(cvp_style/cvp_contour):帧原子元数据的小 FIFO(其中 style 的
  16 深队列被综合成 2 块 ERAM20K)改为单 pend 寄存器,pend_v 复现原满/空溢出检查语义。
- **B 数据通路摘异步复位**(cvp_style/cvp_contour/cvp_window3x3):纯数据延迟链与令牌
  寄存器去掉异步复位(有效/帧标志、状态机、计数器、增益累加全部保留),统一 FF 控制集
  改善打包;首个有效像素前各级随流水恰好写满,有效期内行为不变。
- **C 移除 UART 诊断链**(design_top_wrapper):双 cam_stats + cam_report_uart 三个实例
  (-1337 FF);链路诊断由 UDP 状态包覆盖。

## 验证状态

- RTL:22 项回归全部通过(见 rtl-tests.log),其中 4 项为新增差分测试,新旧实现同激励
  逐位对照(frame_stats 17 帧、style/contour 14 帧 128k 采样点、状态链线上包 CRC)。
- 板级:A/B 类比特经上板功能确认(收图、状态回读、模式轮换正常)。本发布比特(含 C 类)
  在确认后仅移除了串口诊断路径,风险低,建议上板后做一次 UDP 收图复验并在此补记。
- 未重跑 300s 压力轮换、两光源/色卡 AWB 精度、Flash 冷启动与实体模式键专项;状态同 v27。

## 使用与回滚

加载/使用方式与 v27 完全一致:双击 ../../hardware/mainboard/tools/打开收图窗口.bat,
SRAM 断电丢失,重新上板用 PROGRAM_SRAM 加载 camera_to_dsi_display_v29.bit。
恢复 v27:下载 ../v27/camera_to_dsi_display_v27.bit。
文件校验见 manifest.json(.bit 原始字节 SHA256;文字按 CRLF→LF 归一化后校验,与 Git blob 一致)。
