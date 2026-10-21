# 检测模块（detect）输出规格与挂接方案
（供分类侧/集成侧对接用 —— detect 组 2026-09-20）

## 一、我们交付什么

白细胞**检测+框选**：逐帧输出画面里全部白细胞的外接框（最多 10 个）。
分类（LeNet/CellNet）不在此模块内——分类吃我们框出来的 ROI 小图。

交付物 3 样：
1. `det_color_feat.v` —— RGB→HSV + 紫色窗颜色分类（逐像素 4 拍流水）
2. `det_wbc20.v` —— 单遍 CCL + 帧末簇合并，逐细胞外接框（≤10 框）
3. `det_roi_bridge.v` ——【新写】把我们的框翻译成 cvp_patch_bridge 的 roi_* 接口

## 二、输入要求（从 cvp_advanced 的 clean 流取数）

| 信号 | 用途 | 备注 |
|---|---|---|
| clean_valid | 像素有效 | 逐像素 1 拍 |
| clean_rgb[23:0] | RGB888，检测的唯一输入 | **必须白平衡后、风格化前**（clean 流已满足） |
| clean_x / clean_y[11:0] | 像素坐标 | 用于坐标对账 |
| clean_sof | 帧起始 | 我们内部用它复位行/帧计数 |
| clean_eof | 帧结束 | 触发帧末解析（算框） |
| clean_frame_id[31:0] | 帧号 | **原样透传给 roi 输出**——分类结果按帧号对齐靠它 |

约束：clean 流为 1280×720@30fps、100MHz 域。我们逐像素 1 拍流水，
100MHz 下吞吐 100Mpx/s >> 720p×30fps=27.7Mpx/s，无阻塞风险；
**不允许反压**（我们也不会反压）。

## 三、输出规格（给 cvp_patch_bridge / 分类侧）

每帧帧末（eof 后 ~几千拍内完成，30fps 消隐期 ~3.7 万拍，余量充足）
输出 0~10 个框。每框：

| 字段 | 位宽 | 内容 |
|---|---|---|
| roi_bbox[63:0] | 64 | {x0,y0,x1,y1} 各 16bit，**图像坐标**（0,0=左上，与 clean_x/y 同基准），含端点 |
| roi_frame_id | 32 | 透传产生该框的那一帧 clean_frame_id |
| roi_id | 16 | 框在本帧内的序号 0..9（按面积从大到小） |
| roi_cfg_id | 16 | 常量 0（暂无多配置） |
| roi_data[7:0] | 8 | 置 0（我们不供像素；小图像素由 patch_bridge 从原帧裁剪） |
| roi_valid/ready | 1/1 | 标准 valid/ready 握手，SOP/EOP 语义按 patch_bridge 规范 |

**重要语义**：
- 框是"上一帧画面"的结论（帧末锁存、下一帧输出），frame_id 标的是
  产生检测的那一帧——分类侧/GUI 按 frame_id 对齐，勿用当前帧号；
- 不足 10 框时只发实际数目；0 框时整帧不发（不是发空框）；
- 框可能包含非白细胞（当前误检率见回归报告），分类层负责甄别——
  这正是检测+分类分工的意义。

## 四、当前参数与性能账（已 31 张全量回归验证，2026-09-20）

- 色相窗 [123,175]（HUE_CB=700/HUE_BM=996/HUE_MR=1010）、S_MIN=100、
  COMPACT_PCT=37、MIN_AREA=400（720p 口径）、SEED_MIN=256、GAP=2、
  MAXWH=128、FOV 45%、N_OUT=10；
- 31 张全量：品红泄漏 0/31；晚间批误检 10→2~4；正常批真核召回无退化；
- 资源（本地旧工程实测，新工程更宽裕）：~1300 LUT + ~3200 FF + 7 DSP；
- 帧末解析 ≤ 数千拍 << 30fps 消隐 3.7 万拍，无时序风险。

## 五、挂接改动点（动队长文件处，共 2 处，待确认）

1. `design_top_wrapper.v`：cvp_advanced 例化的 clean_* 从悬空改为
   接入 u_det_color_feat 输入（+ det_roi_bridge 输出接 result_* /
   roi 级联）；其余一行不动；
2. 源文件清单登记（build_check.tcl / .al 按仓库规矩）4 个新文件
   （det 3 + bridge 1）。

全部改动走 git 提交（分支 `detect-integration`，评审后合 main）。

## 六、验证计划

1. 最小 TB：合成图（3~5 个"细胞"色块）→ clean 流激励 → 断言框坐标；
2. 复用 tb_v26_patch 查 bridge 握手时序；
3. 全链联合仿真（复用我们 tb_det_ispfeed 管线，激励指向新工程）
   5 张模板图，比对检出与离线镜像；
4. 上板：GUI 看框。
