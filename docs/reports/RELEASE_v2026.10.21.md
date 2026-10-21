# v2026.10.21：工程目录整理与作品报告更新

主板工程移至 `hardware/mainboard/`，HDMI 子板移至 `hardware/hdmi/`；当前训练代码位于 `yolo/wbc_bccd/`，历史发布包和退役 CellNet 位于 `old/`。TD 工程配置只调整引用路径，现有相机、ISP、识别和网络 RTL 继续使用最终候选实现。

作品报告保留官方五部分结构，按当前项目架构更新，并调整摘要、血检应用领域、ISP 与轻量级模型部署说明及性能表。机械设计和成果简述依据 MicroscopeSupport_V10 的设计与几何检查记录；原始 CAD 设计包位于独立目录，不包含在本仓库中。报告 PDF 和 LaTeX 包均为 24 页版本。

当前模型为 `wbc_bccd160_devcam_20261021`，仍为全帧 RGB160 的 FPGA YOLO-style 检测与五分类。视频配置 30 fps，识别每两帧运行一次。最终候选 bit SHA-256：`5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58`。

SRAM 成功下载记录保留；用户反馈实拍改善并自行完成 Flash 烧录。本机自动 Flash 校验失败和用户反馈分别记录，手动烧录文件身份与冷启动未独立核验。已使用 TEST 的结果及未通过原 1% 人工背景误检门槛的记录保持原验证范围。本次没有重新布局布线、下载或烧录。

## 下载后打开工程

1. 在仓库根目录运行 `python tools/configure_project_paths.py`，更新两套 TD 工程的本机路径及 HDMI logo ROM 路径。
2. 打开 `hardware/mainboard/td_project/camera_to_dsi_display.al` 或 `hardware/hdmi/HDMI_OUT.al`。
3. 运行 `python tools/check_project_layout.py --published` 校验工程引用、发布源码、模型、bit、报告和链接。

`--published` 只对待发布文件检查临时产物，不删除本地 TD 构建结果。发布版按 `.gitignore` 排除三项含本地像素的冻结资产：`camera_val.npz`、`data_manifest.json`、`rtl_vectors.zip`；这些文件缺失不会阻止发布范围校验，存在时仍核对哈希。完整数据回放需相应本地资产。

发布检查结果见同目录 `publish_validation_20261021.json`。本轮执行目录/身份检查、Python 单元回归及候选 Git 内容核对；历史 FPGA RTL 仿真和物理结果未在本轮重跑。
