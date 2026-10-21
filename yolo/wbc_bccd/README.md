# WBCAtt+ 与 BCCD 两来源重训

本轮仅使用 WBCAtt+ 的 PBC-Normal 图像及 BCCD。初始化来自从随机权重训练的 WBCAtt-only FP32 checkpoint，不使用 Raabin 图像或 Raabin 训练权重。架构仍为面向 RTL 的单尺度 YOLO-style 检测器，不能称完整移植官方 YOLOv5/v8。

WBCAtt+ 负责 Basophil、Eosinophil、Lymphocyte、Monocyte、Neutrophil 五类及定位；BCCD 只有白细胞框，类别保持 -1，屏蔽分类损失，不制造伪标签。纯色/暗场/噪声是程序化训练增强，不是第三个采集数据集。所有派生裁图随原图划分；准备阶段核对原始及 RGB160 解码重复项，实际跨集合 RGB160 重复为零。

| 划分 | WBCAtt+ 原图 | WBCAtt+ 背景裁图 | BCCD 原图 | BCCD 背景裁图 |
| --- | ---: | ---: | ---: | ---: |
| TRAIN | 6021 | 6020 | 205 | 270 |
| VAL | 1010 | 1010 | 87 | 122 |
| TEST | 3017 | 3017 | 72 | 99 |

TRAIN 原图数量不等于独立患者数量；没有患者级隔离证明。TEST 在先前实验中已被查看，只作为已使用测试集的回归，不称全新盲测。

`protocol.json` 在训练前声明采样、损失、轮数、VAL 选权重与阈值、验收门槛。`prepare.py` 生成不可覆盖的两来源缓存与原图溯源清单。`train.py` 训练 120 轮 FP32 和 80 轮 QAT，并冻结源码与数据哈希。`evaluate_export.py` 先按 VAL 冻结阈值，再检查空场景与已使用 TEST 回归，只有门槛全通过才导出或激活 ROM。

板端保持全帧采样至 RGB160、30fps 视频每两帧推理一次、未推理帧保持上一结果、短暂漏检保持两次推理、单框与英文全称。全部算法在 FPGA，上位机不变；只使用副本中既有 `camera_to_dsi_display.al`。

当前状态：训练、RTL和最终时序检查已完成，模型已成功下载主板SRAM。用户反馈此版实测效果更好，并称已自行完成Flash烧录；本机TD6.2烧录尝试在TDO读回阶段失败，手动烧录未由本机日志独立核验。第一组人工背景误检1.76%未达原1%目标，两组均低于2%试验界限，原失败记录保留。阈值使用了给过的开发截图，不能称仅VAL选择或独立定量实拍验证。详见主板 `reports/yolo_wbc_bccd15/README.md` 与 `deployment_state.json`。

GitHub 版本包含训练代码、最终权重/ROM、主板 bit、数据审计清单和验证摘要；原始训练图像、用户提供的相机截图及包含图像像素的回归向量留在本地，不随仓库发布。
