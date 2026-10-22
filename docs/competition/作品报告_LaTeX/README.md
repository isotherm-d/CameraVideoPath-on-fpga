# 作品报告 LaTeX

2026-10-21 根据整理后的 `camera processing unit` 活动硬件树更新。保留官方五部分、全部章节标题、原始 Word/LaTeX 模板、页眉和 `reportstyle.sty`。已补充主板/子板目录、视频与识别并行连接图、模型资产和位流身份，以及验证与部署证据范围；历史单来源失败压缩为背景说明。

当前模型为 `wbc_bccd160_devcam_20261021`，全帧 RGB160、15 Hz 推理、30 fps 视频、最多一框及英文全称。最终候选 bit SHA-256：`5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58`。全部实时算法在 FPGA；PC 负责原样接收与控制。

SRAM 下载成功已有本机记录。用户随后反馈实拍改善并自行完成 Flash 烧录；本机自动 Flash 操作的 TDO 读回校验失败，用户手动烧录的文件身份及冷启动未独立核验。已使用 TEST 联合 macro-F1 为 91.40%，一组人工背景未达原 1% 门槛；这些结果不等同独立定量相机验收。

在本目录运行两次 `xelatex -interaction=nonstopmode -halt-on-error main.tex`。最新 PDF 为 25 页，无超宽盒、缺字或未解析引用，并已逐页检查。本次核对 203 项发布源码记录、10 项活动模型资产、原始模板哈希与候选 bit 身份，未重跑硬件回归或布局布线。详情见 `verification_summary.json` 和 `release_manifest.json`。

主工程下 `docs/competition/作品报告.pdf` 与本目录 `main.pdf` 内容相同；同级 `作品报告_LaTeX.zip` 为可独立编译的交付包。原位置 `cvp/作品报告_LaTeX/` 同步保留一份副本，后续编辑以主工程文档目录为准。
