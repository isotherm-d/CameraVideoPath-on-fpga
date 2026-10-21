# v30 无 DSI 候选构建

2026-10-12。基于 v29 裁掉主板本地 DDR→DSI 显示支路，保留 1280×720@30fps 相机/ISP、七模式、AE/AWB、OSD、UDP 6000/6001/6002 和 ETHB 镜像。主板 7 寸屏背光关闭。

候选已通过 RTL 回归与 TD 综合/布局布线。**用户于 2026-10-12 反馈上板功能无误**；此记录来自用户反馈，未提供逐项测试清单或烧写文件哈希。助手没有烧写 SRAM 或 Flash，历史 v29 文件保持原样。

工程载入与运行缓存修复（2026-10-12）：清除了旧 ISP/AWB VHDL 注册及主工程运行目录中的旧 DDR 约束缓存。主工程已通过 TD 6.2 的完整综合、布局布线和比特流生成，本目录已更新为该次构建。RTL 未改，22 项回归记录沿用此前同一源码的结果。重新打开工程请使用 TD 6.2。

| 指标 | v29 | 本候选 |
|---|---:|---:|
| Slice | 15006，70.73% | 10523，49.60% |
| LUT6 | 12744 | 8484 |
| FF | 15462 | 10304 |
| ERAM20K | 65 | 51 |
| DSP | 10 | 10 |
| PLL | 4 | 2 |
| DDR byte / MIPI TX | 6 / 1 | 0 / 0 |
| Setup WNS / TNS | +0.102ns / 0 | +0.116ns / 0 |
| Hold WNS / TNS | +0.020ns / 0 | +0.020ns / 0 |

Slice 减少 4483（相对 v29 减少 29.9%），占用率降低 21.13 个百分点；释放 14 块 ERAM 和 2 个 PLL。资源均为 PH1P35MDG324、TD 6.2.168116 布线后实测值。

验证记录：

- 14 个保留实例的端口连接与 v29 相同；12 个显示支路根实例移除。
- 187 个工作区 HDL 文件与用于实际构建的隔离快照匹配。
- 22 项 v29 RTL 回归全部通过，覆盖 ISP/模式/AE/AWB、配置、窗口边界、网络、状态桥及新旧差分。
- 两组线上包由 Python 独立校验 Ethernet CRC、IPv4 checksum 和 UDP 端口，通过。
- setup/hold TNS 均为 0；没有使用放宽保留通路时钟频率来减少资源。

文件：

- [候选比特流](camera_network_only_v30_candidate.bit)
- [布线资源报告](resource_report.txt)
- [布线时序报告](timing_report.txt)
- （原始日志已清理）
- [构建与 SHA256 记录](manifest.json)
- [依赖核查、改动与复现说明](../../../docs/mainboard/V30网络输出与DSI裁剪说明.md)

上板采用 PROGRAM_SRAM 加载候选比特流，先确认 ETHA 收图、ETHB 子板 HDMI 回显和 UDP 控制/状态，再检查模式键和 AE/AWB。此构建不能驱动主板 DSI 屏。

回滚：PROGRAM_SRAM 加载 `../v29/camera_to_dsi_display_v29.bit`。源码恢复使用 v29 基线；工程文件名仍沿用 `camera_to_dsi_display.al`。

后续优化建议见 [v30 资源复审](../../../docs/hardware/V30后续资源优化建议_20261012.md)。本轮仅分析，处理 RTL 与比特流未改。
