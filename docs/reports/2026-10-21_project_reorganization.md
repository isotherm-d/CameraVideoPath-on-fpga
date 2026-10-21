# camera processing unit 目录整理记录

2026-10-21，主工程根目录更名为 `camera processing unit`。Git 工作树已同步迁移，分支为 `main`。

| 目录 | 内容 |
| --- | --- |
| `hardware/mainboard/` | PH1P35 主板：`td_project/` 工程与约束、`user_source/hdl_source/` RTL、`tools/` 脚本、`reports/` 结果 |
| `hardware/hdmi/` | EG4D20 HDMI 子板工程及源码 |
| `yolo/` | 当前训练、量化、导出和仿真代码；复用的 five/robust 模块保留 |
| `docs/competition/` | 原样收录最新官方格式 LaTeX、PDF 和 Word 模板 |
| `docs/design_notes/` | 各功能专题 LaTeX/PDF |
| `docs/hardware/`、`docs/mainboard/`、`docs/hdmi/` | 硬件资料、主板使用和子板集成说明 |
| `docs/history/` | 历史方案和交接记录 |
| `old/` | 旧发布包、退役 CellNet32 模块及历史检查脚本 |
| `tools/` | 工程路径配置与整理后身份校验入口 |

主板 `.al` 名称与内部设计标识继续使用 `camera_to_dsi_display`，原工程配置只修改路径。主板内部工程/源码相对层次保留；HDMI 的 logo ROM 绝对路径随新根目录同步。后续整体移动目录，可运行 `python tools/configure_project_paths.py` 更新本机路径。

共删除 442 个临时文件，其中 367 个日志、56 个 Python 字节码，其余为 LaTeX 辅助文件。空缓存目录一并移除。历史位流、时序/资源报告、权重与必要的冻结测试输入保留；像素测试数据已在 `.gitignore` 中排除公开提交。

整理前的跟踪文件由本地备份分支 `backup/local-reorg-pre-20261021` 保留；原未跟踪文件及迁移/清理清单保存在主工程之外的 `Desktop/2026/backups/CameraVideoPath-yolo-pre-reorg-20261021/`。

验证结果：

- 两个 TD 工程共 131 项文件引用均存在；与整理前项目配置比较，差异仅为路径。
- 原物理构建清单的 203 项输入已核对：202 项源文件字节哈希相同，1 项 `.al` 为上述路径修改。
- 99 个 Python 文件语法检查及 5 个 PowerShell 脚本解析通过。
- 现有 38 项 Python 单元测试在含空格的新路径下全部通过；网络套接字由测试替身隔离，未接管实时查看器。
- 当前文档链接、活动模型资产、冻结训练资产、模板和已交付 PDF 校验通过。
- 新工程目录内无日志、Python/LaTeX 辅助文件或 TD Runs 缓存。

发布 bit SHA256：`5bc2dfee5ef0980b69b3749871bcd768298c5b37af3dcdb67af45930c8ceff58`。
官方 PDF SHA256：`50abbb157ab249e88aca02e7c13596f7a66ec4bfc4232914481ca05791fe4bf8`。

本次为本地目录与路径整理，未重新布局布线、下载或写 Flash；原实板记录继续按原验证范围解释。

## 后续报告修订与版本发布

本记录上方的 PDF 哈希对应最初整理时版本。后续已更新作品报告摘要、血检应用与技术特点，并按显微镜摄像头支架 V10 简述机械设计与成果；最新报告仍为 24 页，哈希以 `docs/competition/作品报告_LaTeX/release_manifest.json` 为准。发布版本 `v2026.10.21` 的源码、模型、bit 与文档检查见 [发布校验摘要](publish_validation_20261021.json)，使用说明见 [发布说明](RELEASE_v2026.10.21.md)。
