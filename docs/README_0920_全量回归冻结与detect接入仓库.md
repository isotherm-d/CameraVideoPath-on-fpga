# README_0920 —— 31 张全量回归冻结参数 + detect 接入队长仓库（detect-integration 分支）

> 2026-10-10 会话。前情：9-19 完成色相偏移发现与重标定落地（README_0919）。
> 本日两大成果：**①31 张全量回归通过、参数冻结；②detect 链正式接入队长
> Git 仓库（新主板工程），bridge 单元回归 11/11**。

## 1. 31 张全量回归（线 A，参数冻结）

清单：六轮测试 31 张（README 与脚本全扫提取，21+10；注意
`20260918_233811` 是 TD 日志时间戳误匹配，非图片）。工具
`_blood_test/reg31_full.py`（8 进程并行，约 25 分钟）+ `reg31_anno/` 标注图。

**结论：通过，参数冻结**：
- **品红侧泄漏 0/31**（放宽段 [158,175] 的 S≥100 像素在多图存在、最多
  2.5 万/图，但无一进入检出框——框中心 60×60 窗品红像素全 0）；
- 晚间批误检大幅清除：181033/181122/181145/181408/190553 等 10 框→2~4 框；
- 正常批真核召回无退化：8 张框数变化图逐张目视（175724/175921/175929/
  180503/180601/181408/190553/113011），**减少的全是 S60 时代误检**；
- 唯一观察项：`20181213_113011` 左下一个边缘淡染分叶核未出框（1/31，
  待查六轮审计口径，不阻塞冻结）。

## 2. detect 接入队长仓库（线 B，detect-integration 分支）

仓库 `CameraVideoPath-on-fpga`（队长，149 commits，v24~v28；双板系统：
主板 PH1P35 UDP 推流 → EG4D20 子板 HDMI 回显）。主板工程
`08_csi_dsi_cs500_7cun`（v27：SC500CS 720p@30fps、25.5% slice、0/40 DSP、
无 detect）。队长批复"按我们的想法来，md 写清楚即可"。

**提交三连（分支 detect-integration）**：
1. `9a197c4 feat(detect)`：det 4 文件移植（冻结参数：窗[123,175]/S100/
   C37/HUE_BM=996/HUE_MR=1010/FOV=0 实时全画幅）+ **det_roi_bridge v3**
   （框→V26 roi 块流：SOP/EOP/1024B GRAY8 块、frame_id 透传、bbox
   {x0,y0,x1,y1} 各 16bit、ready 反压保持、发送中新帧 flush 队头替换）+
   顶层接线（cvp_advanced 的 clean_valid/sof/eof/rgb/frame_id 五根线接
   入检测链；roi 输出 w_roi_valid/w_roi_bbox 调试观测点；result_* 维持
   安全常量；clean_pixel/x/y/cfg_id/eol 仍悬空）；
2. `46a6251 chore`：清仿真产物 + .gitignore；
3. `fa2d648 docs`：`detect/README.md`（参数冻结表/bridge 语义六条/
   时序账/验证状态/已知边界——分类组对接必读）。

**验证**：`tb_det_roi` **11/11 PASSED**（块数/SOP/EOP/bbox/帧号/全零/
反压/flush 换帧）；det 5 模块 vlog 零错误。**顶层 TD 全工程编译待环境**
（build_check.tcl / TD GUI elaborate）——列入待办。

### 调试记录（bridge/TB 联调四坑，供后人）
1. bbox 打包：64bit=4×16bit（12bit 坐标 4'h0 零扩展），曾错写成
   8×16bit 截断；`{16'd0,x,...}` 形式是 128bit 塞 64bit 的经典错；
2. 数框逻辑：FSM 内 for 循环对 reg 非阻塞自加全部基于旧值 → left 恒
   1。要用阻塞 integer 变量数完再寄存；
3. flush 语义：发送中新快照→当前块发完弃剩余，**flush 分支不得清
   s_valid**（新快照还要发）；S_IDLE/S_SOP 收新快照直接作废当前遍历；
4. TB 采样：SOP/EOP 各 1 拍宽，任务式双 while 死等会错过——用
   always 自动采样器（握手拍计数+SOP 快照），且注意 SOP 拍即第 0
   字节（bidx 归 1 防错位）、块 0 字段另存（rbbox0）防被后续块覆盖。

## 3. 与 9-19 的衔接与待办

- 9-19 遗留三件之①（31 张回归）**完成**；②面积 +935 片已定案（本地
  旧工程事项，接入新工程后不再关键——新工程 25.5% slice）；③上板复核
  色相窗 → 待联合仿真+上板；
- 待办（按序）：顶层 TD 全工程编译验证 → 接入版全链联合仿真（5 模板
  图，复用 tb_det_ispfeed 管线指向新工程）→ u_roi_pixfill（像素回读
  裁剪，交付后分类才有真图）→ 上板 → GUI 看框；
- 分工：LeNet 分类=队长；我们=检测框+roi 适配（本次已交付）+
  pixfill+链路验证。

## 4. 接入版全链联合仿真（同日续）：暴露 det_wbc20 真实帧缺陷链

新工程顶层编译验证 ✅（.al 全 155 项 132 个 HDL 文件 vlog 零错误 + 顶层
链接 det 三模块全解析；修复 wire 前移声明两处（ModelSim 严格模式
vlog-2388 隐式线网冲突，TD 无影响）+ ph1p35_ddr_wrapper 补 dhi_clk
声明 + .al 登记 detect 三文件，commit 56947cb）。

随后用 9-19 的真实 ISP 帧（181122 稳态帧 → clean_pix_181122.hex）灌
clean 流联仿（tb_det_newlink.v + run_det_newlink.do），**当场暴露
det_wbc20 从未在真实 720p 帧上跑过的事实**——此前全部回归都是合成
小图。逐层诊断（端口 cid5 → S1 bin1 → S2 op 分布 → live 表 sum →
行直方图 → w_first 计数 → 合成/真实 +SYNTH 二分）每次修复揭开下一层：
1. **NL=16 标签预算耗尽**：真实帧紫游程 ~237+/帧（S_MIN=100 细碎
   噪点），行 ~74 耗尽 16 标签，之后全丢（合成回归只需 <16 从未暴露）；
2. **r_alloc 7bit 回卷 127→0**：标签 ID 重用，晚到碎屑覆盖真核统计
   （"组件只剩 y540-570"之谜真相）；
3. **find2 深度不足**：真实帧合并密度使父链达 3 边 → 升级 find3；
4. **NLW 8bit 装不下 256 溢出为 0**（全部拒绝分配）→ 9bit。
最终 NL=256/LW=8/NLW·r_alloc 9bit 饱和不回卷/扫描指针 8bit/s_amax
9bit：**CCL 记账 557→3,207 px/帧**（离线镜像 4,667；残差=find3 之上
合并残差 + 超预算碎屑拒绝）。commit e74fd55。

**遗留（下一会话第一件事）**：解析层输出退化框（1px box @ (1052,115)，
疑似竖线状解马赛克伪影组件，真核簇未胜出）——查 argmax/R_PREP/R_COMMIT
链；然后 5 模板重验 + u_roi_pixfill。

**方法论沉淀**：逐层计数器 + 行直方图（**integer 数组必须初始化，
X+1=X 陷阱**）+ w_first 计数 + 合成/真实双模式二分（+SYNTH plusarg）
+ $readmemh 相对路径——这套"数据通路验尸流程"可直接复用于 det 链
任何后续问题。另：sim 临时产物别入库（.gitignore 已补）。

## 5. 解析层修复 + det_cid_filter 多数表决（同日深夜续）

**第 5 缺陷：w_eff_best 7bit 截断（commit 626eb6a）**——argmax 的
提交指针 `wire [6:0] w_eff_best = w_better ? r_scan : r_best`，r_scan
已扩 8bit：选中标签号 ≥128（真核分配早计数大必然高号）时 r_eff 截断
成"标签号-128"，R_PREP/R_COMMIT 读碎屑统计，真核框全灭。修复后
**核 A 完精确命中：r_box[0]=(608,240)-(682,278)，与离线零偏差**。

**核 B/C 缺席机制确认**：255 标签预算被行 70-110 的密集碎屑游程
（孤立像素≈一像素一游程）耗尽，行 110 后的真核被拒（live 表全部
标签 y70-134 实锤）。**源头治理 = det_cid_filter 3×3 多数表决**
（commit 5e52ee0）：cid 流 2 行 LUTRAM 缓存 + 3×3 窗口 WBC_CID 计数，
≥5 判紫/中心紫计数不足杀/其他类透传，固定 3 拍；孤立的 1-4px 碎屑
团全死，游程数降一个量级。接线 det_color_feat → cid 滤波 → det_wbc20
（wrapper + TB 同步）。

**遗留（下一会话第一件事，比之前更深）**：滤波器上线后解析层输出
反向异常框 (206,224)-(214,218)（y1<y0）——疑 256 标签下 scratch
簇合并/argmax 的索引问题，需 argmax 逐轮转储（r_round/r_eff/r_bestc
+ scnt top10）定位。CFLT 探针已留 TB。诊断中自摆乌龙两记：①重写
det_cid_filter 丢了行缓存写语句（line1/line2 恒 X，cnt5 恒 X，
全部紫被杀）；②直方图/计数探针的阶段错位（r_bin1 在 r_v2 拍已是
下一像素的值）——探针读多级流水寄存器时必须对齐同一像素的拍点。

## 6. 终极元凶落网：行缓存按 cid 寻址（第 6 缺陷，全部清零）

argmax 逐轮探针显示"假条带"真相：det_wbc20 在 det 行 214-218 每行
收到 **~1,170 个连续紫像素（x=0,1,2,...全行宽）**，而同行真实像素
（TRK2 直读 det_color_feat 出口）S=44→cid=0。矛盾指向 cid 滤波器
→ 揪出**第 6 缺陷（终极元凶）**：3x3 窗口的行缓存读地址误用 cid
移位寄存器 h2/h1/h0（3bit 像素值当 0-7 列地址）——窗口采的是"列
0-7 中 cid 值对应位置"的垃圾；全行误判紫→簇合并链成 1074x6 假
条带占满输出槽。多数表决/开运算两版都带着这个错。
修复：line1/line2 按列计数器 r_x 寻址（r_x-2/r_x-1/r_x，边界补 0）。

**结果：DET_NEWLINK ALL PASSED 7/7**——三核框 (607,241)-(683,278)/
(451,300)-(538,332)/(861,279)-(911,301)，与离线镜像 ±1px；K4 修正
为"两帧×三核=6 块"（桥按帧发块，行为正确）。真实 ISP 帧过完整检测
链端到端验证通过。commit 5838777。

**六个缺陷总账**（全部"合成回归不可见"）：①NL=16 预算耗尽→256；
②r_alloc 回卷→9bit 饱和；③find2→find3；④NLW 8bit 溢出→9bit；
⑤w_eff_best 7bit 截断→8bit；⑥行缓存 cid 寻址→列地址寻址+
cid 滤波器（多数表决/开运算两版迭代，最终多数表决 v2 定版）。

## 7. 6 图新链路批量验证：18/18 全中（同日终章）

TB 参数化（+HEX/+KCHK plusarg，hexfile 声明须在模块级——无名块内
声明违规 vlog-2388 又踩一次）。批量验证 `_blood_test/run5_newlink.py`：
6 图（5 模板 + 181747）真实 ISP 帧过完整链
（det_color_feat→cid 滤波→det_wbc20→det_roi_bridge），

**结果：离线参考 18 框，RTL 命中 18/18，多出 0，逐框偏差 +1~2px**
（cid 滤波器窗口中心 (x-1) 惯例的系统偏移）。亮点：
- 175003 三核全检出——ENABLE_FOV=0 后此前 FOV 外的核不再漏；
- 181122 回归 KCHK 7/7 保持；181747 环核 4/4；
- 181145 一框高度从 438→413（-25px，少数表决对淡染边缘的腐蚀），
  命中判定不受影响。
标注图：detect/nl5_*.png。验证脚本 run5_newlink.py 可复用
（dump→hex→TB→比对→标注一条龙）。commit 629fcc1。

**上板前三步只剩两步**：u_roi_pixfill（分类用，不拦看框）→
TD 综合/时序（NL=256 资源重估）。

## 8. u_roi_pixfill 落地 + 单元验证 5/5（同日收官）

**u_roi_pixfill**（commit 5e49123）：clean 流过时按框快照裁 32x32
灰度（g=(R+2G+B)>>2）到每框 1KB 缓存（LUTRAM，10 框 x 1KB），
逐框 captured 标志（行末越过框第 32 行置位/toggle 清零）；
det_roi_bridge 加 i_captured 逐框门控（S_SOP 等待裁剪完成，帧内
必然完成无死锁）+ o_blk_start（读地址清零）；wrapper 接线
（clean_x/y 前移声明）；.al 登记全部 5 个 detect 文件
（100-104：color/cid_filter/wbc20/bridge/pixfill）。
tb_roi_pixfill 5/5 PASSED：满框 1024 字节逐字节、小框 77 字节、
captured 时序、toggle 清零。

**TB 自摆乌龙两记（记入方法论）**：①px() 函数 integer 直拼
{700%256, 88, 128} = 72bit 截 24bit 丢 R 通道（r/g 先截 8bit 再拼）；
②读选通 3ns 脉冲不跨时钟沿（rdinc 须跨 posedge）。

## 9. 本地 TD 6.2.1 全流程通过——位图已出（同日终章）

**TD 版本澄清**：README 里"TD 5.6.59063"仅指**子板** HDMI_OUT
（EG4D20，Eagle 系需老版 TD）；**主板 PH1P35 工程即 TD 6.2.1 流程**
（同一芯片同一 .al 格式，本地复现全成功）。官方要求 6.2.1 无冲突。

**本地全流程（08_csi_dsi_cs500_7cun/syn_1/）**：settings.cfg 适配
（补 start_step/arr_filter 等 5 个流程变量 + ddr2 IpADCList/IpSDCList
路径）→ .prj 快照由 .al 生成 → DefaultFlow 全步：
read_design→opt_rtl→opt_gate→place→route→bitgen **全绿**。

**布线后**：SWNS +0.104ns / HWNS +0.020ns / **0 违例端点** /
slice 81.77%（17,349/21,216）——**camera_to_dsi_display.bit 已出**。
期间综合抓到**第 7 个缺陷**：det_roi_bridge 的 s_valid 被两个 always
块同时驱动（ModelSim 事件顺序容忍、综合 HDL-8007 拒绝）——s_valid
收归 FSM 单块管理（tog_edge 置位放 case 后最高优先级），回归 7/7
保持。commit db70033。

**上板清单**：detect-integration 分支位图 PROGRAM_SRAM 加载 →
相机对显微图 → GUI（tools/cam_gui_v27.py，UDP6000）看框
→ 分类核接入后 pixfill 真实小图进 patch_bridge，GUI 显示类别。

**已知余量事项**：81.77% 布线利用率偏高（NL=256 标签表 42Kb 以
FF/LUTRAM 形态为主）——时序已过可上板；若需余量，后续把 live/
scratch 表迁 ERAM 可回收大半（调研项非必须）。

## 10. 资源墙与解法（同日第三轮，N_OUT=5 + 开运算 + ERAM/回收决策）

**功能推进**：N_OUT 10→5（五文件联动，实际核数 3-4 有余量）；
det_bin_open3（1bit 开运算）串入多数表决后——联仿 7/7 保持，
r_alloc 256→200（commit 9979dd7）。

**资源墙实测（本地 TD 6.2.1）**：NL=128 需 23,792 slice = **112.14%**
（det_wbc20 表格 20.2k FF 落触发器为主体；此前"81.77% 通过"一次
实为 .prj 未含 cid_filter/pixfill 时的黑盒剪枝假象）。资源数学：
NL=128 表 20.5k FF + 基础 14k FF，打包后 112%；NL=160 约 80% 可
放下但需求 200 > 160 功能不足；NL=208 资源临界 ~96% 危险。
**单纯调 NL 无解，必须结构性改造。**

**解法（已定，下一步实施）**：
- A. **标签回收**：组件关闭（某行无像素即永久关闭，4 连通性质）
  时标签入空闲栈，新组件从栈弹出——把"累计需求 200"压到"同时
  存活 ~40"，NL=128 变真正充裕。需 per-label lasty 跟踪 + 空闲栈
  + 分配改弹栈。
- B. **scratch 七数组迁 ERAM**：解析 FSM 本就多周期串行（COPY
  1/拍、JUMP 3 拍/条、合并 2 拍/对），加"地址预置"读拍即兼容
  ERAM 同步读——省 11.6k FF。live 表同拍读必须留 LUTRAM/FF。
- A+B 后预估 slice ~75%，且任何帧不再耗尽标签。
- N_OUT=5 已完成；验收 = 联仿 7/7 + 本地综合 ≤85% + 时序正。

**经验教训新增**：③探测/激励代码同样会踩"integer 拼接截断"和
"选通脉宽不跨沿"坑；④综合器抓多驱动（HDL-8007）是仿真不可替代
的一道闸——每轮 RTL 改动后必须先过综合再看仿真。

## 8. u_roi_pixfill 落地 + 单元验证 5/5（同日收官）

**u_roi_pixfill**（commit 5e49123）：clean 流过时按框快照裁 32x32
灰度（g=(R+2G+B)>>2）到每框 1KB 缓存（LUTRAM，10 框 x 1KB），
逐框 captured 标志（行末越过框第 32 行置位/toggle 清零）；
det_roi_bridge 加 i_captured 逐框门控（S_SOP 等待裁剪完成，帧内
必然完成无死锁）+ o_blk_start（读地址清零）；wrapper 接线
（clean_x/y 前移声明）；.al 登记全部 5 个 detect 文件
（100-104：color/cid_filter/wbc20/bridge/pixfill）。
tb_roi_pixfill 5/5 PASSED：满框 1024 字节逐字节、小框 77 字节、
captured 时序、toggle 清零。

**TB 自摆乌龙两记（记入方法论）**：①px() 函数 integer 直拼
{700%256, 88, 128} = 72bit 截 24bit 丢 R 通道（r/g 先截 8bit 再拼）；
②读选通 3ns 脉冲不跨时钟沿（rdinc 须跨 posedge）。

**下一步 = 上板流程**：detect-integration 分支交队长 → 队长 TD 5.6
综合布线（本地 6.2.1 与 IP 版本锁定不兼容，不冒然跑）→ 时序复核
（NL=256 资源增量：live/scratch 表 16→256 约 +9k FF → LUTRAM/
ERAM 重映射后估 +3~5k LUT等效，新工程 25.5%→~30% 量级，充裕）
→ PROGRAM_SRAM 上板 → GUI 看框（检测框实时显示）
→ pixfill 数据进 patch_bridge（分类核就位后分类结果显示）。
