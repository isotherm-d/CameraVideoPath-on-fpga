# README_1011_备份与重新接入指引（detect-integration @ 413fd09）

> 2026-10-11。队长推送更新、仓库将重新对齐前，对 detect 组全部工作做的
> 一次性备份。本文档 = 备份清单 + 恢复方法 + 重接入步骤。

## 1. 备份位置与内容

备份目录：`E:\TD_6.2.1\PROJECT\backup_20261011\`

| 文件 | 内容 |
|---|---|
| `cvp_fpga_detect_20261011.bundle` | **git bundle（完整历史）**：detect-integration @ 413fd09 + main（队长基线）全部提交 |
| `al_working_snapshot.al` | 工作区 .al 快照（TD 最新重存态：detect 无排除、顺序 140-144、4 个 ISP 文件被 TD 标 AutoExcluded） |
| `README_1010*.md / README_1011*.md` | 本组全部会话文档（方案 A/B 全记录、资源对账表、副板盘点） |
| `run_tmp_images.py / al_fix_loop.py / al_test.tcl / fix_eram.py` | 关键工具脚本（域外图检测流水线、.al 分析修复循环、ERAM 迁移补丁器） |

## 2. 恢复方法（任选其一）

```bash
# 方式一：从 bundle 克隆（离线、不依赖 GitHub）
git clone E:\TD_6.2.1\PROJECT\backup_20261011\cvp_fpga_detect_20261011.bundle cvp_restored
cd cvp_restored && git checkout detect-integration

# 方式二：在现有仓库里从 bundle 拉取
git fetch E:\TD_6.2.1\PROJECT\backup_20261011\cvp_fpga_detect_20261011.bundle detect-integration:detect-integration-restored
```

## 3. 我们的工作摘要（detect-integration 相对 main 的提交链）

| 提交 | 内容 |
|---|---|
| 9f0f32d | 方案 A：标签回收（live 表 208→64，含水位播种/幽影/父指针竞态三修复）|
| bcfc324 | 方案 B：scratch 七数组迁 ERAM（A/B 双副本，与基线逐位一致）|
| 413fd09 | .al 修复：移除 11 个不可独立分析的 .vh/.vhd 条目（**注意：该提交的 .al 内混入了 TD 回写污染**——detect 五文件被标 AutoExcluded/151-155，重接入时以 `al_working_snapshot.al` 或重跑 al_add_detect.py 为准）|
| e02accc 及更早 | NL=208、bridge 描述符直通 GUI、pixfill、cid_filter、open3、18/18 批量验证等 |

外部资产（不在 git 内）：`E:\TD_6.2.1\PROJECT\docs\`（全部会话文档）、
`E:\TD_6.2.1\PROJECT\_blood_test\`（离线实验区全脚本）、
`detect-integration` 分支上的 detect 五文件即交付物。

## 4. 重接入步骤（队长更新拉取后）

1. `git fetch origin` → 检查 `git log HEAD..origin/main --oneline` 看队长改了什么；
2. 从新 main 建分支 `detect-integration-v2`；
3. 拷入 detect 五文件（`user_source/hdl_source/detect/`：det_color_feat / det_cid_filter /
   det_wbc20 / det_roi_bridge / u_roi_pixfill + tb_det_newlink.v）；
4. .al 登记：跑 `_blood_test/al_add_detect.py`（或手工按 CompileOrder 200-204
   登记五文件、**不设 AutoExcluded**）；
5. 顶层接线：`design_top_wrapper.v` 的 clean 流五抽头 + result_* 直通
   （锚点见 `detect/README.md` 与 V26 对接文档）；
6. 回归链：桥 11/11 → pixfill 5/5 → 联仿 7/7（+KCHK）→ 6 图 18/18；
7. 综合测占用（syn_1 流程，见 syn_howto.md）。

## 5. 已知坑（重接入时必读）

- **.al 会被 TD GUI 回写**：GUI 运行/关闭可能把 AutoExcluded/顺序改写——
  GUI 提示保存一律选"否"，以 git 为准；
- **.al 新建分析不理会 AutoExcluded**：清单里不能有"不可独立分析"的
  .vh/.vhd 条目（11 个已移除清单见 413fd09 提交说明）；纯 `define 型可留；
- ModelSim 仿真产物、syn_1 综合产物不入库；
- `run_tmp_images.py` 等脚本依赖 `_blood_test` 的绝对路径布局。
