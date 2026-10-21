# detect —— 白细胞检测链（2026-10-10 接入 v27 主板工程）

本目录是 detect 组的交付：**白细胞检测+框选**（分类/LeNet 不在此列，
由分类组接 `cvp_patch_bridge` 下游）。对接规格全文见
`docs/detect_对接规格书_v1.md`（本仓库外的工作文档，入库副本见文末）。

## 文件

| 文件 | 作用 |
|---|---|
| `det_color_feat.v` | RGB→HSV + 8 类颜色分类（逐像素 4 拍流水，无除法） |
| `det_shape_feat.v` / `det_feat_top.v` | 形状特征/特征顶层（本链未例化，保留供回归） |
| `det_wbc20.v` | 单遍 CCL + 帧末簇合并 → 逐细胞外接框 ≤10 个 |
| `det_roi_bridge.v` | 【新】框总线 → V26 roi 块流翻译（含丢帧/反压语义） |
| `tb_det_roi.v` + `run_det_roi.do` | bridge 单元回归（11 检查，一键跑） |

## 已接线（design_top_wrapper.v，2026-10-10）

`cvp_advanced` 的 `clean_valid/sof/eof/rgb/frame_id` → `det_color_feat`
→ `det_wbc20` → `det_roi_bridge`。输出观测点 `w_roi_valid` / `w_roi_bbox`；
`result_*` 维持安全常量（分类核未接入）。**clean_pixel/x/y/cfg_id/eol
仍悬空**（检测用不到）。顶层改动 = cvp_advanced 例化处 5 根线改接 +
新增一个例化块，其余一行未动。

## 关键参数（31 张全量回归冻结版，2026-09-20）

`HUE_CB=700 / HUE_BM=996 / HUE_MR=1010 / S_MIN=100 / COMPACT_PCT=37 /
MIN_AREA=400 / SEED_MIN=256 / MERGE_GAP=2 / MERGE_MAXWH=128 / N_OUT=10 /
ENABLE_FOV=0`。回归结论：品红侧泄漏 0/31、晚间批误检 10→2~4、正常批
真核召回无退化。**BM/MR 必须同步抬**（判决链 RED 先于 BLUE，单抬 BM
会在 [BM,939) 形成死代码）。色彩标定细节见项目组 docs/README_0919。

## det_roi_bridge 语义（分类组必读）

- 每有效框发一个 1024 字节块（SOP 随第 0 字节、EOP 随第 1023 字节），
  GRAY8、32×32；`i_pix_en=0` 时发全零块（协议合法）——像素回读填充
  （u_roi_pixfill，从 clean 流行缓存裁 32×32）后续交付；
- `bbox 64bit = {x0,y0,x1,y1} 各 16bit`（12bit 坐标零扩展），原图坐标；
- `frame_id` = **产生检测的那一帧**（det 帧末用上一帧像素算框，输出保持
  一整帧）——分类/GUI 按 frame_id 对齐，勿用当前帧号；
- `i_ready=0` 反压：块内暂停、不丢不重；发送中收到新帧快照：当前块
  完整发完（EOP）后放弃剩余旧框，回 IDLE 用新快照重启（队头替换，
  不混帧），patch_bridge 的 dropped 口计数此类放弃；
- 0 框帧不发任何块；roi_id = 框在本帧内序号（按面积降序）。

## 时序账

逐像素 1 拍流水（100Mpx/s >> 720p30 的 27.7Mpx/s，不反压不拥塞）；
帧末解析数千拍 << 30fps 帧间 3.33M 拍；bridge 10 框 × 1024 拍 = 10240
拍/帧，余量 300 倍。

## 验证状态

- `tb_det_roi`：11/11 PASSED（块数/SOP/EOP/bbox/帧号/全零/反压/flush）；
- det 4 模块：移植自原工程，回归 1-6 全过（原工程 2026-09-19 记录）；
- 顶层 wrapper：语法自查通过，**TD 全工程编译待环境**（build_check.tcl
  或 TD GUI 打开工程 elaborate 一次）；
- 上板：待新链路 5 模板图联合仿真后烧写验证。

## 已知边界

- roi 像素当前为全零块（分类精度无效），等 u_roi_pixfill；
- 30fps 下框更新率 = 30Hz（帧末锁存语义），GUI 按 frame_id 对齐即可；
- `113011` 类边缘淡染分叶核可能漏检（31 张回归唯一观察项，占 1/31）。
