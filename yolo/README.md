# FPGA YOLO-style 白细胞检测与分类

当前主工程模型为 **WBCAtt+ + BCCD 联合训练版** `wbc_bccd160_devcam_20261021`，已接入 PH1P35 主板项目。它是面向本板资源设计的定点 YOLO-style 检测器，不是完整移植的 Ultralytics YOLO。

- 训练、数据审计、权重冻结与复现：[wbc_bccd/README.md](wbc_bccd/README.md)
- 当前板端验证和资源时序：[主板报告](../08_csi_dsi_cs500_7cun/reports/yolo_wbc_bccd15/README.md)
- 两来源技术文档：[官方格式报告](../docs/README_1021_WBCAtt与BCCD两来源重训.md)
- 最终候选 bit：[camera_to_dsi_display.bit](../08_csi_dsi_cs500_7cun/reports/yolo_wbc_bccd15/current/physical/camera_to_dsi_display.bit)

## 主板行为

输入为 720p 全帧，FPGA 在片上缩放到 160×160 RGB；每两帧推理一次，视频仍以 30fps 输出。框选、目标选择、五类分类、后处理、单框英文全称叠加以及跳帧结果保持均在 FPGA 完成。画面最多显示一个细胞，类别为 Basophil、Eosinophil、Lymphocyte、Monocyte、Neutrophil。PC 和 HDMI 仅接收带板端叠加的视频。

最终物理结果：19016/21216 Slice、94/108 ERAM、35/40 DSP，setup/hold WNS 为 +0.102/+0.020ns。bit SHA-256 为 `5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58`。

## 结果边界

WBCAtt+ 已使用 TEST 联合 macro-F1 为 91.40%，但该 TEST 在之前实验中被检查过，不能视为新的独立盲测。两组程序化空场景误检率分别为 1.76% 与 0.78%，原定 1% 门槛未通过；当前版本按工程试验版归档。阈值使用过开发场景校准。用户反馈实拍效果较前版更好并表示已手动完成 Flash 烧录，但本机未独立核验手动烧录的文件哈希或冷启动状态。

早期 WBCAtt-only 与 CellNet32 路径不属于当前发布；`five/` 中部分训练与校准代码仍被复用。训练用图像数据和含像素的回归向量不随本次主线提交；获取 WBCAtt+ 与 BCCD 数据后，可按 `wbc_bccd/README.md` 中的审计与训练步骤重跑。
