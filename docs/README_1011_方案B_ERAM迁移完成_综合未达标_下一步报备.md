# README_1011 —— 方案B（scratch 迁 ERAM）完成：机制成功，综合 129% 未达标

> 2026-10-11 会话（接 README_1010）。一句话：**ERAM 迁移机制完全达成
> （scratch 离开 LUT、det_wbc20 LUT 25.9k→7.0k、内部状态与基线逐位
> 一致、回归全绿，commit bcfc324）；但整片 gate 129.17% 仍超限——
> 新瓶颈定位为 live 表 FF 寄存器堆的多读口 mux。下一步（live 表
> LUTRAM 化）属新结构改动，已报备待批。**

## 1. 实施内容（commit bcfc324，仅动 detect 组两文件）

det_wbc20.v：
- scratch 七数组各配 **A/B 两副本**（`ram_style="block"`，SDP 形状：
  单写口 + 同步读），合并扫描需同拍读 i/j 两地址由双副本解决；
- 五处写源（COPY / 关闭 burst / J_WR / B3 / M_APPLY）汇为**每数组唯一
  写位点**（统一写口 w_wa/w_wd_*/w_we_*——这正是 323% 爆片的病灶）；
- 解析 FSM 同步读预置拍：COPY 1 拍/项不变、JUMP 3→4 拍/项（嵌套读
  拆两级 A1/A2/A3/WR）、BSUM 1→3 拍/项（乘积寄存）、合并 1→2 拍/对
  （M_WT 稳读）、argmax 1→2 拍/项（RSW/RSC）；R_PREP 顺带寄存框坐标
  （RCM 不再读表）；状态机 0..11 扩为 0..17；
- s_dead/s_taken 按位写位向量留 FF；dout 无复位（首帧未写槽位 X 与
  旧版 distributed 行为一致，s_amax 边界保证有效槽位必已写）；
- **关闭搬运保留基线 7 拍 burst 节奏**（rc1..rc6 分拍写、rc7 落账）。

## 2. 关键教训：1 拍写优化引发内部状态漂移（已回退）

首版把 burst 收敛为"1 拍写 6 数组 + rc1 落账"——功能回归 7/7 过、框全对，
但 scratch 转储与基线不一致（slot40/667→slot43/701，SUM 19510→19513，
一个 34px 碎片被双计并沿吸收链放大至 +272）。根因：标签提前 6 拍回到
空闲栈 → 后续分配的标签号序列改变 → 按号比合并方向下树形变化 → find3
深链半路节点落账分布改变。**修法：恢复基线 7 拍 burst，仅把写路由到统
一写口** → 内部状态与基线逐位一致（帧 1/帧 2 diff 均空）。
**教训："框输出一致"不等于"内部一致"；改回收时序必须逐拍对齐基线。**

## 3. 验证（全绿）

- 联仿 tb_det_newlink +KCHK：**7/7**；
- scratch 转储 vs 基线：**帧 1、帧 2 逐位一致**（diff 空）；
- 6 图批量 run5_newlink.py：**18/18 全中、多出 0**；
- 桥 11/11、pixfill 5/5（模块未动，复跑确认）。

## 4. 综合结果：机制成功，资源未达标

| 指标 | 破碎版（B前） | ERAM 版（本次） | 目标 |
|---|---|---|---|
| det_wbc20 LUT | 25,858 | **6,951** | — |
| 整片 dram lut | 1,584 | 1,392 | — |
| **ERAM** | 27/108 | **74/108（68.5%）** | 推断成功 ✓ |
| 整片 gate | 68,634（323%） | **27,404（129.17%）** | ≤85% ✗ |
| place | 32,198 失败 | 26,816 失败（PHY-9053） | — |

层次 Top（gate.area）：**u_det_wbc 8,244（最大单模块）** > advanced
5,833（style 2,721 / stats 1,895 / contour 969 / median 802）> ddr2
2,433 > eth 792。

**新瓶颈定位**：det_wbc20 剩余 8.2k 中，scratch 已进 ERAM，大头是
**live 表（64×91b FF 寄存器堆）的多读口 64:1 mux**——S3 读改写一拍内
要读 cnt[idm]+cnt[idM]+mnx/mxx/mny/mxy×2 ≈ 16 端口 × 64:1，约 4-5k
LUT，另有 5.8k FF 落片。

## 5. 下一步（已报备，待批后才动工）

**方案 C 候选：live 表大数组迁 LUTRAM**（cnt/mnx/mxx/mny/mxy 5 数组，
parent/lasty/closed 视写口情况定）——README_0920 §10 原文即写明
"live 表同拍读必须留 **LUTRAM**/FF"，本方向在计划字面范围内，但当前
live 表是纯 FF 实现，改 LUTRAM 属新结构改动：
- 每拍写口分析：cnt/mnx/mxx/mny/mxy 每拍恰 1 写（r_idm）✓；
  parent 每拍 1 写（S2：分配自指或合并 idM）✓；lasty 合并拍需写
  idm+idM 两处 ✗（需留 FF 或改判定结构）；
- LUTRAM 异步读天然提供 64:1 读口，预计 live 表 mux ~4-5k LUT 收缩
  到 ~1k；det_wbc20 预估 8.2k→3-4k；
- **预期整片 ~104%（22.2k）——仍高于 85% 目标**：85% = 18,034 片，
  是给队长 LeNet 留的余量线。若 C 后仍 ~104%，剩余缺口需在更上游
  （N_OUT、advanced 域、或与队长协商基线）——**这部分是队长的地盘，
  必须由你来协调**。
- 备选小刀：NL 64→32（实测同时存活 10-12，余量 5 倍，可再省 ~1.5k）
  可与 C 叠加。

## 6. 本会话工具异常记录（供后人）

本会话多次出现工具返回内容与磁盘不符/自相矛盾的情况（读文件返回与
提交版不符的内容、断言失败却输出"通过"日志等）。对策已固化：**一切
以 git + 磁盘 grep 交叉验证为准，不凭会话内记忆/返回内容下结论；
关键动作前后各做一次地面真值核实。**

## 7. 当前状态

- 分支 detect-integration：bcfc324（B 段成果已提交，功能层完整可信）；
- 工作区干净；
- 综合产物 syn_1/（129% 报告）不入库；
- 待办：等 live-LUTRAM 方向批复 → C 段实施 → 全量回归 → 综合复测。

## 8. .al 被 TD GUI 回写污染事件（2026-10-11，已修复）

用户在 TD GUI 打开 td_project/camera_to_dsi_display.al 跑综合，报 5 错
（.vhd/.vh 分析失败）。排查发现工作区 .al 处于未提交的坏状态：**detect
五文件被标 AutoExcluded=true、CompileOrder 变 151-155、Project Path 被
改写为本地路径、缩进重排**——而 git 里的 .al（队长提交版）一直是正确
的（无排除、200-204）。即：**谁从这份被回写的 .al 跑综合，detect 会被
静默排除**（综合"通过"但没有检测模块——历史上 81.77%/25.5% 的口径混
乱很可能也有此贡献）。

- 根因：TD GUI 运行/关闭时自动重存 .al，把其内存态（含自动排除决定）
  写回——即队长所说"改了 ui 同步不过去 然后又回写回去"；
- 修复：`git checkout -- td_project/camera_to_dsi_display.al` 恢复提交
  版（未提交的 GUI 改动被丢弃，无需新提交）；
- 规矩：**GUI 里跑完工程若提示保存 .al，一律选"否"**；.al 以 git 为准；
  队长本机的 .al 也建议用 git diff 自查是否被同样回写过。
- 遗留：.vhd/.vh 两文件在 .al 与 .prj 中标记一致（均 AutoExcluded），
  但 GUI 新建分析流程仍会独立分析它们并报错——GUI 路线若复现，改开
  syn_1/camera_to_dsi_display.prj（CLI 已验证全绿的快照），并请队长
  提供其 GUI 正常跑通的步骤。

## 9. 域外实验：8 张用户自备图 × ERAM 版检测链（2026-10-11）

用户放 8 张 575×575 血涂片裁剪图（D:\Users\Krypton\Desktop\JNU\临时测试），
跑完整部署链：真实 ISP RTL 联仿（DPC/demosaic/AWB，3 帧）→ clean 流 →
ERAM 版检测链（color_feat→cid_filter→open3→wbc20）→ 标注图存
`临时测试\新建文件夹\*_det.png`。驱动：_blood_test/run_tmp_images.py
（3 路并行 ~30 分钟；坑：cv2.imread/imwrite 不支持中文路径，经
tmp_in/tmp_out ASCII 中转）。

结果：致密紫核全部命中（16dc 单核精准 0 误检、c16b R3、c039 R3 中性粒
带状核），另散布少量可疑小框（RBC 边缘/染液碎屑）；e7df 0 框=漏检——
两个巨大紫核超 MAX_AREA_PCT=15% 帧面积上限（极端特写域，细胞远大于
标定域）。定性：**域外图片上"真核必中"保持，假阳/漏检来自域偏移**
（标定域=手机过目镜 4160×3120 全视野；本批=不同来源裁剪+575→720p
横向 2.2× 拉伸）。参数如需适配新域，按冻结流程重跑 31 张回归后再定。

## 10. v29 重接入完成 + 联合占用实测（2026-10-11 深夜）

**备份**：`E:\TD_6.2.1\PROJECT\backup_20261011\`（git bundle 完整历史
@413fd09 + .al 快照 + 文档/脚本，恢复方法见
README_1011_备份与重新接入指引.md）。

**拉取**：队长推送 v29 基座优化（b66d0cb+5140d37）：style/contour/
frame_stats/window3x3 优化 + 新增 cvp_status_bridge（并入 eth_dbg）+
UART 诊断链裁剪，**基座 slice 17,359→15,006（70.73%）、FF −23%**，
配 gold 模型逐比特回归，附 resource_report.txt/timing_report.txt。

**重接入**（分支 `detect-integration-v2`，3 提交）：
- 967d7f5：五文件+TB 拷入、.al 登记（200-204/无排除）+ 移除 11 个
  不可分析条目、wrapper 接线（三方补丁干净应用）；
- c8d5887：修正三方补丁副作用——旧 main 的 cam_check 三实例
  （cam_stats×2/cam_report_uart，v29 已删其源文件）被补丁复活成黑盒，
  两处区域回退 v29 原状；另恢复被切分支删掉的 syn_1/settings.cfg；
- 8c89ade（前）：.al 修正 413fd09 混入的 GUI 回写污染。

**回归（v29 基座全绿）**：联仿 7/7、6 图 18/18、桥 11/11、pixfill 5/5。

**联合占用实测（gate）**：**24,363 slice = 114.83%**（place 24,077
超限 PHY-9053）。detect 链在 v29 上实占 = 24,363 − 15,006 = **9,357 片**。

**方案 C 定靶（由估算变精确）**：
- ≤100%（放得下出位图）：需砍 **≥3,147 片** → C 预估 4-5k ⇒ 够；
- 85%（18,034，LeNet 线）：需砍 **≥6,329 片** → C 4-5k + NL 64→32
  （~1k）≈ 5.5-6k ⇒ 差 ~300-800 片，需基座再挤或 LeNet 去副板（28
  DSP 闲置）。

## 11. 方案 C 实施：live 表大数组迁 LUTRAM（2026-10-11 深夜）

**迁移分配**（写口分析定边界）：cnt(4 读口)/mnx/mxx/mny/mxy(各 4)/
parent(8)/slot(4)/free_st(1) → distributed LUTRAM，每读口一副本（异步
读=FF 同语义）；lasty/closed 留 FF（合并拍双写 idm+idM / 帧界批量复
位——LUTRAM 单写口装不下）。find2/find3 函数移除改显式三级链；迁移
数组删复位环（分配先于读的不变量由父指针竞态修复保证）。

**实施中修的 4 个错**（均为补丁机械错，非概念错）：rcfire/rc7fire 命名
错位；reaper 分支 slot[r_rp] 漏改；读口线网块先用后声明（w_wa 引用
w_slot_aS 在其声明之前——vlog 报 undefined+already declared 对儿）；
TB 探针改名漏 12 处。

**验证（全绿）**：联仿 7/7；scratch 转储与基线逐位一致（SUM 19510/
20028 同）；6 图 18/18；桥 11/11；pixfill 5/5。综合实测见后续提交。

### C 综合实测（TD 6.2.1 DefaultFlow，全流程通过，位图已出）

| 指标 | B 后 | **C 后实测** | 目标 |
|---|---|---|---|
| det_wbc20 logic LUT | 8,244 | **1,981（−76%）** | — |
| det_wbc20 DFF | 6,951 | **1,894（−73%）** | — |
| 整片 f7 宽选择器 | 2,824 | **376（−87%）** | — |
| 整片 dram lut | 1,392 | 1,744（+352，符合预估 300-500 ✓） | — |
| 整片 slice（gate） | 27,404 | **18,051 = 85.08%** | ≤85% ✓ 压线 |
| 整片 slice（route） | — | **18,965 = 89.4%** | <100% ✓ |
| place / route / bitgen | 失败 | **全通过，位图已出** | ✓ |
| Setup | — | **WNS +103ps、TNS 0** ✓ | 正 |

**LeNet 线判定**：gate 85.08% vs 目标 85%（18,034）——差 **17 片**，正好
压线。NL 64→32（实测同时存活 10-12，裕量 2.7 倍）一刀再省 ~1k 片 →
gate ~80.3%，稳过线。是否切 32 待 owner 决定。

**唯一时序瑕疵（队长域，非 detect）**：Hold WNS −36ps（fast corner 单
端点），位于 `u_eth_dbg/u_fifo`（125M GMII 域的分布式 RAM FIFO）——
队长 v29 对 cvp_eth_dbg 的优化（+87 行）可能引入。Setup 零违例。
建议转达队长复核；detect 域时序干净。
