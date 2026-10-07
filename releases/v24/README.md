# v24 上板文件

首次测试选择 `PROGRAM_SRAM`，下载 `camera_to_dsi_display_v24.bit`。本目录由 TD 6.2.168116 针对 PH1P35MDG324 重新综合、布局布线并生成，启动/命令回归测试通过。实物出图尚未验证。

时序：建立裕量 0.028 ns，保持裕量 0.020 ns，建立/保持总负裕量均为 0。详情见 timing_summary.txt，资源使用见 resource_report.txt，文件校验值见 manifest.json。

恢复旧程序：使用相邻 `before-v24-20261006` 目录中的原比特流。完整修复说明见 `../../08_csi_dsi_cs500_7cun/V24修复说明.md`。
