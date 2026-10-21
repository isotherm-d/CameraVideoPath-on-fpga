# ⭐ README_000_v4 —— 新会话必读（v38 重接入定稿，2026-10-15）

> **本文是 detect 组最新交接文档**，接替旧版 README_000（v2 时代，已含
> 大量历史）。读完本文即可上手；深挖细节按文末索引跳转
> README_0920/1010/1011/1012。**纪律红线见 §8，先读再动手。**

## 0. 项目一句话 + 当前状态（2026-10-15 定稿）

实时血细胞检测系统：SC500CS 相机 → 主板 PH1P35 FPGA（MIPI→ISP→
**白细胞检测框选**）→ 千兆 UDP → PC GUI 画框。**detect 组负责检测+框选；
分类 LeNet 归队长**。

**当前状态：v38 重接入定稿，全部验证通过，交付位图已出。**

| 项 | 数值/状态 |
|---|---|
| 基座 | 队长 v38（network-only 精简版：DDR/DSI/display 全裁，PID 6/3/1 曝光环） |
| detect 全链 | color_feat→cid_filter→**open3**→wbc20（回收+LUTRAM）→bridge→**叠加** |
| slice（route 后） | **16,233 = 76.51%**（LeNet 预留线 85% 之下，余 ~1.8k 片）|
| 时序 | Setup +144ps / **Hold +21ps** 全正 |
| 位图 | `syn_1\camera_to_dsi_display.bit`（每晚重建后取最新）|
| 板上验证 | 标定卡 B 格（窗中心）出框 ✓、D 格（窗外）无框 ✓、像素烤框可见 ✓ |
| 分支 | **`detect-integration-v3`**（重接入定稿 @ 1820d84）|

## 1. 三大工作区与关键路径

| 区 | 路径 | 说明 |
|---|---|---|
| **队长仓库（主战场）** | `E:\TD_6.2.1\PROJECT\CameraVideoPath-on-fpga` | git 管理；我们全在 `detect-integration-v3` 分支 |
| ├ 主板工程 | `...\hardware\mainboard\td_project\camera_to_dsi_display.al` | 主工程（TD GUI 打开这个）|
| ├ 我们的交付 | `...\hardware\mainboard\user_source\hdl_source\detect\` | **七文件+3TB**（v3 定稿）|
| ├ 综合目录 | `...\hardware\mainboard\syn_1\` | settings.cfg（已适配 v38 无 DDR）+ DefaultFlow 跑法见 syn_howto.md |
| ├ 队长发布 | `...\old\releases\` | v24~v38-candidate（v38=network-only 精简+PID 曝光环）|
| 旧本地工程 | `E:\TD_6.2.1\PROJECT\CameraVideoPath` | detect 原始开发地（参考+老 TB）|
| 离线实验区 | `E:\TD_6.2.1\PROJECT\_blood_test` | 全套脚本：run5_newlink.py（6图批量）、run_ispfeed.py（ISP联仿）、al_fix_loop.py（.al修复）、run_tmp_images.py（域外图流水线）|
| 会话文档 | `E:\TD_6.2.1\PROJECT\docs\` | README_000~1012 按序读 |
| 备份 | `E:\TD_6.2.1\PROJECT\backup_20261011\` | git bundle@413fd09 + .al 快照（旧 v29 定稿）|
| **主板资料** | `E:\02_F02_FC02_PH1P35\02_hardware\HW_MLKPAI-F02-20250425-FC02-20241023` | MLKPAI-F02+FC02（PH1P35MDG324）：硬件手册/原理图/引脚表；关键引脚已提取到 `_blood_test\f02_base.txt` |
| **副板资料** | `E:\01_F01_FC01_EG4D` | MLKPAI-F01+FC01（**EG4D20**，TD 5.6）：HDMI 输出副板 |
| 副板工程 | `CameraVideoPath-on-fpga\hardware\hdmi\` | EG4D20 网口收流→HDMI（队长域，v28 含 logo OSD）|

## 2. 工具链

| 工具 | 路径 | 备注 |
|---|---|---|
| TD 6.2.1（主板综合/下载） | `E:\TD_6.2.1\bin\td_commands_prompt.exe` | 命令行：`cd syn_1 && td_commands_prompt.exe E:/TD_6.2.1/doc/scripts/DefaultFlow.tcl`（**正斜杠**）；GUI 主程序 `td.exe`；BitWriter 下载位图 |
| ModelSim 10.3c | `E:\altera\14.1\modelsim_ase\win32aloem\vsim.exe` | 联仿一键 do 在 detect/ 目录 |
| Python 3.12 | `C:\Users\Krypton\AppData\Local\Programs\Python\Python312\python.exe` | cv2/numpy；**一律 `python -X utf8`** |
| git | `C:\Program Files\Git\cmd\git.exe` | bash 语法（`cd /d` 不可用）|
| 显示流截图测量 | 见 `_blood_test` 各探针脚本 | cv2 中文路径会静默失败——**走 ASCII 中转** |

## 3. 板卡要点

**主板 MLKPAI-F02**（PH1P35MDG324：38k LUT/42k FF/108 ERAM/40 DSP/21216 slice）：
无 HDMI 无拨码；3 按键；25M 时钟 C4；相机 SC500CS 走 MIPI CSI（I2C=T9/U9、
PWDNB=V8）；千兆网口 ETHA→PC（UDP 6000 视频/6001 控制/6002 状态）、
ETHB→副板镜像；JTAG=CH9102F USB Type-C。位图 PROGRAM_SRAM 易失加载。

**副板 MLKPAI-F01**（EG4D20EG176）：收主板 ETHB 镜像流 → DDR 三缓冲 →
HDMI 720p60 + 安路 logo OSD（v28 已交付）。**PLL 4/4 满**；余量 LUT 12k/
BRAM 20/DSP 28。**副板 HDMI 尚无检测框**——画框已由主板像素烤框实现，
镜像流自动携带（副板零改动即可见框）。

## 4. detect 链（交付态）

```
adv 流（显示流，1px/拍）→ det_color_feat（HSV 紫窗分类 700/996/1010/S100）
→ det_cid_filter（3×3 多数表决）→ det_bin_open3（3×3 开运算）
→ det_wbc20（NL=64 CCL+回收+LUTRAM；簇合并；N_OUT=5）
→ det_roi_bridge（→描述符，板上断链已绕开）
→ cvp_box_overlay（像素烤框：常量框 i_test_en=0 关闭 + 检测框空心 2px）
→ pack_4 → UDP 6000 → PC GUI
```

**冻结参数**：色相窗 [123,175]（RTL 700/996/1010）、S_MIN=100、
MIN_AREA=400、COMPACT_PCT=37、MAX_AREA_PCT=15、MERGE_GAP=2、
SEED_MIN=256、N_OUT=5、NL=64（LUTRAM+回收）。

**关键架构决策（勿回退）**：
1. 检测输入 = **adv 显示流**（clean 抽头板上疑似无数据；ORIG 模式两者
   像素相同；白点标记 i_mark_en=1 可随时可视化 clean 判定）；
2. live 表大数组 = **LUTRAM**（每读口一副本；lasty/closed 留 FF——多点写）；
3. scratch 七数组 = **ERAM**（A/B 双副本，统一写口）；
4. 检测框 = **像素烤框**（cvp_box_overlay）——描述符链（frame_id 匹配）
   板上断链已绕开；修复归分类核阶段。

## 5. 已完成 ✅

- A 回收 + B ERAM + C LUTRAM（live 表）三连——129%→80.42%（v29 基座）
- v29→v38 两轮重接入，回归全绿（7/7+18/18+11/11+5/5）
- 板上验证：标定卡 B 格（窗中心）出框、D 格（窗外）正确无框
- 像素烤框叠加：板上首框成功，空心描边 2px
- open3 wrapper 例化补齐（板上链=验证链修正）
- .al 修复：11 个不可分析条目移除（脚本化 al_fix_loop.py）
- v38 联合综合：76.51% route / 时序全正 / 位图出
- 备份 backup_20261011/ + 重接入指引 README_1011

## 6. 未完成 / 未来

| 项 | 说明 |
|---|---|
| **显微镜域适配** | 冻结参数在真实显微域的复核（同款标定卡 + 31 张回归）；屏幕翻拍域已验证调参方法论（白点图+标定卡闭环）|
| **分类核（LeNet）接入** | 队长域；ROI 小图通路（pixfill）板上疑似剪枝（79 LUT）需先查明；描述符链 frame_id 匹配断链需修复 |
| **clean 抽头悬空之谜** | 检测已改接显示流绕开；若需 clean 流（双路检测）须先查根因（白点标记一行开启）|
| **副板 HDMI 看框** | 主板像素烤框后镜像流自动携带——副板零改动；待上板连 ETHB 验证 |
| hold −36ps | 一次构建的记录，干净重建消失（并发构建污染），留档备查 |
| NL=32 小刀 | 未启用（本轮 76.51% 已够；如需再挤 ~1.5% 可切）|

## 7. 上板操作（第一阶段已跑通）

1. 硬件：主板 5V 供电 + SC500CS 相机（MIPI CSI）+ USB Type-C（CH9102F
   JTAG）+ 网线 ETHA↔PC（点对点）；**副板不接**；
2. BitWriter → 加载 `syn_1\camera_to_dsi_display.bit` → PROGRAM_SRAM
   （易失，断电重下）；
3. `tools\打开收图窗口.bat`（自动配网卡 192.168.1.100/24 + 开 GUI）；
4. 显微目镜对准血涂片 → GUI 看空心绿框；
5. **已知表现（屏幕翻拍域）**：紫/蓝紫出框、暗蓝区误检、边缘色不稳；
   白点标记（i_mark_en=1）可可视化原始判定。

## 8. 纪律红线（必须遵守）

1. **一步一步来，每段做完写 md**（`docs\README_MMDD_主题.md`）——团队
   唯一知识沉淀渠道；
2. **队长的文件不随便动**（rtl/isp/net/sim/tools/*.al/constraints/old/releases/
   HDMI_OUT 全部）；detect 目录 + wrapper 的 detect 接线段是我们的；
3. **有想法先报备**，不自创方法绕过计划（本轮"写引擎/槽位方向"两绕路
   证伪的教训）；
4. **.al 修改前先关 TD GUI**（GUI 回写会抹条目）；改完 .al 立即重生成
   syn_1 的 .prj；
5. **同一 syn_1 目录禁止并行 TD 流程**（文件竞争会污染位图/报告）；
6. **cv2 中文路径**：imread/imwrite 都会静默失败——走 ASCII 中转；
7. **仿真产物/综合产物不入库**（syn_1 产物曾误扫入，已清理 1631aa0）；
8. **补丁锚点**：与实际文本差一个空格都会 count=0——用 grep/cat -A
   对齐后再跑；脚本落盘前必有 assert；
9. 上下文不够先写交接再收尾（本文即产物）。

## 9. 调试史速查（细节见对应 README）

| 事件 | 结论/修法 | 详见 |
|---|---|---|
| 323% 爆片 | scratch 写法破坏 LUTRAM 推断 → 迁 ERAM | README_1010 |
| "写引擎/槽位方向"两绕路证伪 | 实验基线被污染导致误判——先保证基线干净 | README_1011 §4 |
| open3 缺失（wrapper 未例化） | 补例化=板上链与验证链一致 | a4516d4 |
| 父指针一拍竞态（焊接） | parent 写集中 S2 判定拍 | README_1010 §4.2 |
| 水位播种/幽影 | r_fst1 播种 + lasty 刷合并行 | README_1010 |
| y 位置依赖（下部无框） | v29 高拥塞特有（94.68% 装箱退化）；v38（76.51%）板上未复现；未再深究 | README_1012 |
| .al GUI 回写污染 | 改 .al 前关 GUI；git 为准 | README_1011 §7 |

## 10. 给下一棒的第一周建议

1. 读本文 + README_0920/1010/1011/1012（按序）；
2. 上板复跑：下载 `syn_1\camera_to_dsi_display.bit`（v38 交付态最新）→
   标定卡验证 B 格出框 → 确认基线；
3. 有显微镜：域适配（标定卡对齐 → 31 张回归 → 参数冻结更新）；
4. 与队长对齐 LeNet 接入计划（资源已备 ~1.8k 片余量 + pixfill 通路修复）。
