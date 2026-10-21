# ⭐ 新会话必读 —— 项目总览 · 协作规范 · 当前进度（v3，2026-10-10 重写）

> **⚠️ 本文档已过时（v3 = v29 时代）。最新交接文档是
> `README_000_v4_新会话必读_v38重接入定稿.md`（v38 重接入定稿、76.51%、
> 板上验证通过）——新会话请先读 v4，本文仅作历史参考。**

> v2（2026-09-18，旧板工程时代）已归档为 `README_000_v2_归档_20260918.md`。

---

## 0. 现状一句话（先读这段）

实时血细胞检测系统：相机 → 主板 FPGA（MIPI→ISP→**白细胞检测框选**）→
千兆 UDP → PC 上位机（Python GUI 收图+画框）/ 子板（EG4D20）HDMI 回显。
我们（detect 组）负责**白细胞检测+框选**；队长负责 ISP/分类 LeNet/显示。
**当前：detect 已接入队长仓库并完成全部仿真验证（6 图 18/18 框全中），
卡在 det_wbc20 资源墙（NL=128 仍 112% 切片），解法已定（标签回收 +
scratch 迁 ERAM），实施后即可综合出位图上板。**

## 1. 三大工作区与路径（本机实际路径）

| 区 | 路径 | 说明 |
|---|---|---|
| **主战场（队长仓库）** | `E:\TD_6.2.1\PROJECT\CameraVideoPath-on-fpga` | GitHub `isotherm-d/CameraVideoPath-on-fpga`，git 管理，我们的改动全在分支 `detect-integration` |
| ├ 主板工程 | `...\hardware\mainboard\` | v27 验收基线：PH1P35MDG324 + SC500CS 720p@30fps，含 UDP 发送与上位机 |
| ├ ├ 顶层 | `...\user_source\hdl_source\design_top_wrapper.v` | detect 接入点：搜 `w_det_`/`u_cid_filter`/`u_det_roi`；cvp_advanced 的 clean_*/result_* 接口 |
| ├ ├ 我们的文件 | `...\user_source\hdl_source\detect\` | det_color_feat/det_wbc20/det_cid_filter/det_roi_bridge/u_roi_pixfill + 3 个 TB + README.md（**含各自的 do 一键回归**） |
| ├ ├ 挂接协议 | `...\V26队友挂接示例.md` + `V26开发与接口说明.md` | clean_* 像素流 / patch_bridge ROI / result_* 回传，对接必读 |
| ├ └ 工程文件 | `...\td_project\camera_to_dsi_display.al` | detect 五文件已登记 CompileOrder 200-204 |
| ├ 子板工程 | `...\hardware\hdmi\` | EG4D20，收 UDP 流出 HDMI 720p60（队长域，我们不动） |
| └ 版本发布 | `...\old\releases\` | v24-v28 位图与验收记录 |
| 旧本地工程（参考） | `E:\TD_6.2.1\PROJECT\CameraVideoPath` | 老 HX1P35 板工程，detect 原始开发地；参数冻结/时序战争历史记录在此；`detect/rtl` 为文件源头 |
| 离线实验区 | `E:\TD_6.2.1\PROJECT\_blood_test` | Python 镜像、ISP 联仿（run_ispfeed.py）、批量验证（run5_newlink.py）、诊断脚本全套 |
| **板卡资料** | `E:\02_F02_FC02_PH1P35\02_hardware\HW_MLKPAI-F02-20250425-FC02-20241023` | 主板 MLKPAI-F02 + 核心板 FC02 硬件手册/原理图/pinlist（关键页已提取到 `_blood_test\f02_base.txt`、`fc02_core.txt`） |
| 显微镜原图 | `D:\Users\Krypton\Desktop\JNU\FPGA\images` | 711 张 4160×3120 手机经目镜拍摄；31 张已测名单见 README_0920 |
| 对话文档 | `E:\TD_6.2.1\PROJECT\docs\README_*.md` | 每次会话一份，按日期序读 |

## 2. 工具路径

| 工具 | 路径/版本 | 备注 |
|---|---|---|
| TD（主板综合） | `E:\TD_6.2.1\bin\td_commands_prompt.exe`，版本 6.2.168116 | 官方要求 6.2.1；主板 PH1P35 必须用 6.x（仓库 README 的"TD 5.6"仅指子板 EG4D20） |
| ModelSim | `E:\altera\14.1\modelsim_ase\win32aloem` | 10.3c；一个 TB 一个 do；**$finish 会中止 do 脚本** |
| Python | `C:\Users\Krypton\AppData\Local\Programs\Python\Python312\python.exe` | cv2/numpy/PyMuPDF 已装；脚本一律 `python -X utf8` 且**不要**重复包装 stdout（双重 TextIOWrapper 会关流） |
| Git | `C:\Program Files\Git\cmd\git.exe` | 2.55.0 已装；注意本会话 shell 是 bash 语法（`cd /d` 不可用） |

## 3. 系统拓扑与板卡要点

```
SC500CS MIPI(2lane) → 主板 PH1P35（MLKPAI-F02）→ 千兆 UDP → PC GUI
                     （我们 detect 在此）         └→ 子板 EG4D20（HDMI_OUT）→ HDMI 720p60
```

- 主板=米联客 MLKPAI-F02 底板 + FC02 核心板；FPGA **PH1P35MDG324**（LUT4 38,189/DFF 42,432/DSP 40/ERAM 108×20Kb/Dis-RAM 507）；DDR2 512Mb；FLASH GD25WQ128E。
- **主板无 HDMI**——显示走子板方案（队长已验收）；**无拨码开关**，仅 3 按键（SW1=R10/SW2=N2/SW3=J14）；时钟 25M 单端（C4，与旧板同位）。
- 相机 SC500CS 接 MIPI CSI 座（2lane 兼容 4lane 座）；SC500CS I2C：T9/U9；PWDNB=V8。
- 上位机：PC 网卡 192.168.1.100/24；`tools/打开收图窗口.bat` 自动配 IP；收图 UDP6000、控制 UDP6001、状态 UDP6002。
- 板卡资料完整路径见第 1 节；引脚/外设细节读 `_blood_test\f02_base.txt`。

## 4. detect 现状（核心资产，接手必读）

### 4.1 已冻结的交付参数（31 张全量回归+品红零泄漏背书）
色相窗 [123,175]（HUE_CB=700/HUE_BM=996/**HUE_MR=1010**——BM/MR 必须同步抬，
否则 [BM,939) 被 RED 类拦截成死代码）+ S_MIN=100 + COMPACT_PCT=37 +
SEED_MIN=256 + MERGE_GAP=2 + MAXWH=128 + MIN_AREA=400（720p）+
ENABLE_FOV=0 + **N_OUT=5** + **NL=128** + cid 多数表决 + bin open3。

### 4.2 已修复的真实帧缺陷总账（全部"合成回归不可见"）
①NL=16 预算耗尽→扩容；②r_alloc 7bit 回卷→9bit 饱和；③find2→find3；
④NLW 8bit 溢出→9bit；⑤argmax w_eff_best 7bit 截断→8bit；⑥cid 滤波器
行缓存误用 cid 做地址→列地址；⑦s_valid/d_pend 双 always 多驱动→单块
（**综合 HDL-8007 抓多驱动，仿真不可替代，每轮 RTL 改完先过综合**）。

### 4.3 资源墙（当前唯一拦路问题）
本地 TD 6.2.1 综合：**NL=128 也需 23,792 slice = 112.14%**（det_wbc20 的
live/scratch 表格 20.2k FF 落触发器为主体；NL=256 约 40k FF 更不可能）。
真实帧标签需求 r_alloc=200/帧 > 128。
**已定解法**：A. 标签回收（组件关闭即入空闲栈——4 连通下组件某行无像素
即永久关闭，classic CCL 技巧，把"累计 200"压成"同时存活 ~40"）；
B. scratch 七数组迁 ERAM（解析 FSM 本就多周期串行，加地址预置读拍即可，
省 11.6k FF；live 表同拍读必须留 LUTRAM/FF）。A+B 后预估 slice ~75%。
其余 squeezed 项：N_OUT 已 5→不可再降；cid filter/open3 已加。

### 4.4 验证体系（改动后必跑，全部一键 do）
| 级 | 命令（cwd=detect/） | 通过标准 |
|---|---|---|
| 桥单元 | `vsim -c -do "do run_det_roi.do"` | 11/11 |
| pixfill 单元 | `vsim -c -do "do run_roi_pixfill.do"` | 5/5 |
| 真实帧联仿 | `vsim -c "+KCHK=1" ... tb_det_newlink`（见 run_det_newlink.do） | 7/7（181122 三核 ±2px） |
| 6 图批量 | `_blood_test\run5_newlink.py` | 18/18 框 ±2px |
| 综合 | syn_1 目录 `td_commands_prompt.exe DefaultFlow.tcl` | 0 ERROR |
注意：真实帧联仿的激励 hex 由 `_blood_test\dump_to_cleanhex.py` 从
ispfeed dump 生成（帧 4=稳态）；换图先跑 run_ispfeed.py 产出 dump。

## 5. 协作规范（红线，必须遵守）

1. **队长的文件绝不随便动**。队长文件清单：`rtl/`、`imgproc/`、`isp/`、
   `net/`、`sim/`、`tools/`、`*.al`、`constraints/`、`hardware/hdmi/`、
   `old/releases/` 全部；我们的只有 `user_source/hdl_source/detect/` 与
   `docs/` 的 README。**必须改时**（如顶层接线）：detect-integration
   分支上改 + 规范书写 md 记录 + 提交说明写清改动点 + 让队长知道；
2. **每次会话/每轮改动必须在 `E:\TD_6.2.1\PROJECT\docs\` 写
   `README_MMDD_主题.md`**，命名规范、按日期序、含数据与结论——这是
   团队唯一的知识沉淀渠道；
3. `.al` 与 `.prj` 必须同步（TD 读 .prj 快照）；`.prj` 由 `.al` 生成
   （`_blood_test` 的脚本有生成代码示例）；
4. **git 提交纪律**：源码/配置/文档入库；仿真产物（work/、transcript、
   日志、.bit、.db）不入库（.gitignore 已配）；提交说明写清"改了什么/
   为什么/验证结果"；
5. 上下文有限时：先写交接文档再收尾（本文件就是产物）；
6. 探针/激励代码同样会踩 Verilog 位宽坑——integer 拼接截断、选通脉宽
   不跨沿、X+1=X——TB 失败先查 TB 自己。

## 6. 当前待办（按序）

1. **【下一个实施项】det_wbc20 标签回收 + scratch 迁 ERAM**（解资源墙，
   详见 README_0920 第 10 节；预计 1-2 天含回归）；
2. 完成后本地综合（syn_1 目录流程已通）确认 ≤85% → 时序正 → 位图；
3. **上板**：PROGRAM_SRAM 加载 `camera_to_dsi_display.bit` → 相机对
   显微图 → PC 跑 `tools/cam_gui_v27.py`（网卡 192.168.1.100/24，
   `tools/打开收图窗口.bat` 可自动配 IP）→ GUI 看框（class=0 即检出框）；
4. 上板复核项：真实相机色相偏移量（窗可能偏宽）、真实游程密度（标签
   压力复核）、AWB 实际增益；
5. 分类核接入（队长 LeNet）后：pixfill 真实小图进 patch_bridge，
   class 从 0 换真实类别，GUI 显示"框+类别"。

## 7. 已知坑清单（工具与代码，血泪浓缩）

**工具类**：本会话 shell 是 bash（`cd /d`、`copy` 不可用，用 POSIX 路径
与 `cp`）；多行 `python -c` 静默失败→写成脚本文件；`findstr` 空格串拆
词用 `/c:`；`;` 分隔符会漏进 vsim 参数；ModelSim 10.3c 解不了 TD 新版
加密段（ph1p_phy_ddrphy_byte.v）、无名块内声明违规、$finish 中止 do；
TD 综合器会抓多驱动/黑盒——**仿真过了不等于综合过**；`.area` 报告可能
是陈旧快照（以布线日志 utilization 表为准）；`place effort` 参数无效。
**代码类**：integer 直拼 72bit 截断丢高位（先截 8bit 再拼）；选通脉冲
须跨时钟沿；integer 数组不初始化则 X+1=X；行缓存地址用列计数器不是
数据值；探针读多级流水寄存器须对齐同一像素拍点；两个 always 驱动同一
reg 仿真容忍综合拒绝。

## 8. 31 张已测图与标注图

- 名单与审计口径：README_0920 第 1 节 + `docs/README_0919`；
- 标注图：`_blood_test\reg31_anno\`（NL=128 参数版）、
  `microscope\template_s100c37\`（JPG 域）、
  detect\sim\sim_tmp\isp_det\ 与 isp_demo\（ISP 帧）；
- 已知观察项：20181213_113011 左下一个边缘淡染分叶核未出框（1/31）。

## 9. 历史文档索引（按时间序）

- `README_000_v2_归档_20260918.md`（旧板工程时代的总览，参数冻结/
  时序战争/白细胞方案演变——历史背景仍有价值）
- `README_2026-09-15_血细胞检测可行性分析.md`（首份）
- `README_2026-09-15_同步审计与AWB-v2验证.md`
- `README_2026-09-16_重接入与白细胞20目标CCL.md`（20 目标版，已否决）
- `README_2026-09-16_白细胞10目标重接入与时序收敛.md`（10 目标落地）
- `README_2026-09-16_显微镜抽测第3轮5张新图.md`
- `README_2026-09-18_帧末簇合并拆框修复.md`（簇合并方案全记录）
- `README_0919_模板五张复跑与CellNet报告全文核对.md`（参数重标定+
  CellNet 分析+资源墙初现）
- `README_0920_全量回归冻结与detect接入仓库.md`（31 张回归冻结+
  6 缺陷修复+接入仓库，**本文件的详细支撑记录**）
- `detect_对接规格书_v1.md`（detect↔分类对接规格，队长已批）
