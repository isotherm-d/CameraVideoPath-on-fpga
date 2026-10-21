# v32 黑屏复现基准

`cvp_advanced_v32_gold.v` 是 v32 发布时的图像核心，仅重命名模块。恢复原模块名后的 LF 归一化 SHA256 与 v32 manifest 一致。

`tb_v26_fault_recovery` 对新旧核心输入相同的六帧图像，在第一帧的采集计数中故意少报一组 RAW。两边输出像素、帧首/帧尾和帧号一致；旧版的 fault 永久保持，新版在正常帧恢复后解除 fault，累计错误仍为 1。该基准不参与 FPGA 综合。
