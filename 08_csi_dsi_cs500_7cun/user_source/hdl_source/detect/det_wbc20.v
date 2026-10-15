/*
 * ============================================================================
 * det_wbc20 —— 白细胞逐目标检测：单遍连通域标记（CCL）+ 帧末簇合并，
 *               最多同时 10 个外接框（扩展要求 2：目标检测与识别）
 *
 * 链路位置：
 *   det_color_feat（颜色分类 o_cid）直连【det_wbc20：阈值判定 + 连通域/坐标计算】
 *   → OSD 框接口（o_box_xy/text/color，格式与 det_blob3 相同，宽度 N_OUT 框）
 *
 * 【与 det_blob3 的区别】det_blob3 是"每颜色一个框"（同色合并，最多 3 框）；
 * 本模块对**一种**白细胞颜色类做真正的单遍 union-find 连通域标记，
 * **每个细胞一个框**，最多同时输出 N_OUT=10 个，帧末按面积取最大的 10 个
 * （不足 10 个时剩余框全 F 关闭）。摄像头平移扫过图片时（解读A）：每帧对
 * 视野内全部白细胞重检测，新进入视野的细胞在下一帧末自动获得自己的框——
 * 无需跟踪状态。延迟 = 1 帧检测锁存 + 显示通路固有 1~2 帧（约 33~50ms@60fps）。
 *
 * 【算法：单遍 CCL（4-连通），1 像素/拍】
 *   对 i_cid==WBC_CID 的像素（S2 拍判定）：
 *     left = 上一像素的游程根（r_run）；up = 行缓存里上一行同列的根
 *     都空            -> 分配新标签（帧首从 0 号重分配），初始化统计
 *     有一个          -> 沿用该根，统计累加当前像素
 *     两个且不同      -> union：parent[大根]=小根，大根统计折算进小根
 *   行缓存 line_lab[IMG_W] 存**已解析根**（根缓存，异步读同
 *   imgproc_win3x3 的"同址先读后写取旧值"约定），实际父链深度 <=2，
 *   find 只走两级。4-连通：仅对角相触的细胞保持独立，对计数有利。
 *   统计（cnt/min/max）在判定后一拍写入，与判定流水的行缓存写解耦。
 *
 * 【标签回收（2026-10-10，方案 A 解资源墙）：NL 208->64】
 *   真实帧累计标签 110+/帧（碎屑游程），但同时存活的组件只有 ~40——
 *   碎屑多为单行孤立游程，4 连通下"某行无像素即永久关闭"。本版：
 *     - live 表每项加 lasty（最后活跃行）/ slot（scratch 槽位号，帧内
 *       单调递增分配，与标签号解耦）/ closed 标志，加空闲栈 free_st；
 *     - 后台 reaper（1 标签/拍）扫描：lasty <= 当前行-2 的组件已不可
 *       能再收到任何像素（要收必须经上一行 up 邻居），用 7 拍串行
 *       burst 把统计搬进 scratch[slot]（槽位与标签号解耦：同帧内槽位
 *       不复用，先关闭的组件数据一直保留到帧末），标签压入空闲栈；
 *     - 分配改"弹栈优先"（栈空退回单调递增 r_alloc，耗尽仍放弃）；
 *     - EOF 拷贝只搬未关闭标签（关闭件已在 scratch），COPY 时把
 *       parent（标签号域）翻译成槽位号（scratch 内部全槽位域）；
 *     - 顺序安全性（三条论证）：
 *       ①1 行迟滞关闭 => line_lab 上一行快照/up 路径零悬挂引用；
 *       ②合并吸收的大号标签比幸存小号更早停止活跃，reaper 升序扫描
 *         保证翻译 parent->slot 时幸存者槽位仍有效（槽位只在重分配
 *         时变更，而重分配必在关闭之后）；
 *       ③本行被合并/沿用的标签 lasty>=y-1，永不满足关闭条件 =>
 *         burst 期间其 live 表项无写竞争，读数稳定。
 *     - reaper 推进门控：解析 FSM 空闲、行首 4 拍后（上行 S3 写完）、
 *       末行之外（burst 不与 eof4 后的 COPY 撞写）、分配窗两拍之外
 *       （弹栈/压栈不与 r_sp 读改写撞车）。
 *
 * 【帧末簇合并（2026-09-16 新增）：分叶核拆框修复】
 *   分叶核白细胞各核叶在二值图上常分离成多个组件（4-连通不桥接细缝），
 *   旧版会输出"一细胞多框"或把小核叶滤掉。本版在帧末解析阶段先把
 *   "外接框互相邻近"的组件合并成一个簇再选框：
 *     参与资格 = 组件像素数 >= SEED_MIN（种子）。不足种子的碎屑完全
 *               不参与合并——稀疏碎块若被并入会把簇填充率拉低到阈值下
 *               误杀真细胞（181408 实测），且碎块自身也下不了框；
 *     合并条件 = 双方框扩 MERGE_GAP 后相交，且并集框宽高均 <= MERGE_MAXWH
 *               （白细胞物理尺寸上限，防止沿杂质链级联）；
 *     合并语义 = 像素和累加、框取并集、分件框面积和累加（只算种子）；
 *     扫描顺序 = i 升序、j 升序，整表反复扫描直至无合并（上限 NL-1 轮），
 *               与 Python 离线镜像/TB 参考模型逐拍同构。
 *   紧凑度改为双支路：整框填充率（簇像素和/并集框面积）**或**分件填充率
 *   （簇像素和/分件框面积和）>= COMPACT_PCT。环形/花斑状细胞簇整框填充率
 *   低但分件各自紧凑，由分件支路救回；光晕环/RBC 细链的"件"本身稀疏，
 *   两支路都过不了，过滤能力不回退。MERGE_GAP=0 且无并集时与旧版行为一致。
 *
 * 【帧末解析（消隐期内，只碰 scratch 副本，与逐像素通路零冲突）】
 *   eof+4 拍把 live 表中**未关闭**的标签拷贝到 scratch 的各自 slot
 *   （关闭件已被 reaper 提前搬入；本帧组件总数 = ns_cnt，即扫描边界
 *   s_amax）→ 4 拍/项指针压平 + 3 拍/项分件面积和（ERAM 同步读预置拍）
 *   → 簇合并扫描（≤(NL-1) 轮 × s_amax²/2 拍）→ 最多 N_OUT 轮 argmax
 *   （每轮扫 0..amax-1，取未选中的 cnt 最大者，cnt<MIN_AREA 不参选）
 *   → 锁存 N_OUT 个框（-1 换算回图像坐标）。总拍数 ~万拍量级，
 *   在帧间隙（硬件 v-blank 约 7.4 万拍）内完成，live 坐标不会被下一
 *   帧的重分配影响（框提交读 scratch 并集框）。输出一整帧保持。
 *   面积关键：scratch 七数组迁 ERAM（方案 B，A/B 双副本双读口）；
 *   COPY 1 拍/项、JUMP 4 拍/项、BSUM 3 拍/项、合并 2 拍/对，解析 FSM
 *   多周期串行吸收同步读延迟，写口五源汇为每数组唯一写位点。
 *
 * 【输出格式】与 det_blob3/OSD 完全一致：
 *   o_box_xy    每框 48bit={x0,y0,x1,y1} 各 12bit（x0 在框内最高 12bit，
 *               图像坐标；全 12'hFFF = 关闭该框）；框 0 在总线最低 48bit。
 *   o_box_text  每框 8 字节 ASCII（最左字符在最高字节），
 *               自动 "WBC-01  ".."WBC-10  "（字符全在 OSD 字库内）。
 *   o_box_color 每框 RGB888 = BOX_COLOR（默认亮绿，血图上醒目）。
 *   o_frame_done 单拍脉冲；o_box_toggle 每次更新翻转（CDC 采样指示）。
 *
 * 【资源/时序】live 标签表 64 项（74+10+8+1 bit ≈ 6k DFF，回收前 208 项
 *   15k+ DFF 是资源墙主因）+ scratch 256 槽×A/B（ERAM，槽位=本帧全部组件，
 *   含 reaper 提前关闭的）+ 1280x6b 行缓存（ERAM/LUTRAM）；无除法无 DSP。
 *   逐像素 1 拍流水，100MHz 下 720p60（55Mpx/s）余量大。空闲栈耗尽时
 *   放弃最新组件（r_giveup 可探针），不阻塞流水。
 *
 * 【已知限制】
 *   - 只识别一种颜色类（白细胞核紫色窗，配合 det_color_feat 的 HUE_CB/HUE_BM
 *     重设 246°~316°，血图实测 96% 归槽、与红细胞 0 漏槽）；
 *   - find 深度上限 2（find3 走三级）：极端细长组件的晚合并可能解析不全
 *     （碎片会被 MIN_AREA/簇合并吸收），紧凑团块（细胞核）不受影响；
 *   - 高度稀疏的整块组件（如核叶绕中心排成大环、填充率<COMPACT_PCT 且
 *     单件即整体）仍会被紧凑度过滤丢弃——簇合并只救"多件碎裂"，救不了
 *     "单件稀疏"（20181211_181747 实测 1 例，43k 像素填充率 35%）；
 *   - 相邻过近（框扩 MERGE_GAP 后相交）的两个独立细胞会并成一框——
 *     与"拆框"相比是更可接受的错误方向。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_wbc20 #(
    parameter IMG_W = 1280,                 // 图像宽（行缓存深度，<=4095）
    parameter IMG_H = 720,                  // 图像高
    parameter [2:0]  WBC_CID  = 3'd5,       // 白细胞颜色类（默认蓝槽）
    parameter [11:0] MIN_AREA = 12'd400,    // 细胞最少像素数（滤噪/滤碎片，
                                            //   簇合并后按簇像素和判定）
    parameter integer N_OUT   = 5,         // 最多同时输出的框数
    parameter [23:0]  BOX_COLOR = 24'h00ff3c, // 框颜色（亮绿）
    parameter [11:0]  COORD_ADJ = 12'd1,    // 槽位->图像坐标偏移：
                                            // 上游=det_feat_top（3x3 窗口）时 1；
                                            // 上游=det_color_feat 直连（无窗口）时 0
    parameter         ENABLE_FOV = 1'b0,    // 1=圆形视野掩码（拍屏/打印显微镜图时
                                            //   启用，剔除目镜边缘光晕环与暗角）
    parameter integer FOV_R_PCT = 45,       // FOV 半径 = FOV_R_PCT% × min(W,H)
    parameter integer COMPACT_PCT = 45,     // 紧凑度下限%：整框填充率或分件填充率
                                            //   达标即可（见文件头"帧末簇合并"节）
    parameter integer MAX_AREA_PCT = 15,    // 单组件面积上限%（占整帧面积，
                                            //   超大的环/整图级组件直接丢弃）
    parameter [11:0]  MERGE_GAP = 12'd0,    // 簇合并：框双向扩 MERGE_GAP 后相交
                                            //   则合并；0=仅框相交才合并（近似旧行为）
    parameter integer SEED_MIN = 1,         // 簇合并种子下限：像素数达标的组件才能
                                            //   参与合并（不足者完全不参与，防稀释）
    parameter integer MERGE_MAXWH = 4096,   // 簇并集框宽/高上限（白细胞物理尺寸，
                                            //   防止合并沿杂质链无限扩张）
    parameter integer NL = 64,              // live 标签表深度 = 同时存活组件上限
                                            // （2026-10-10 标签回收：真实帧同时
                                            //  存活 ~40，63 个可用标签充裕）
    parameter integer NS = 256,             // scratch 槽位总数 = 本帧组件总数上限
                                            // （槽位帧内单调分配不复用，含 reaper
                                            //  提前关闭的组件）
    parameter integer RECYCLE_EN = 1,       // 1=标签回收（默认）；0=退回旧式单调
                                            //   分配（联仿二分诊断用，综合可留）
    parameter integer POP_EN = 1            // 1=弹栈重用标签（默认）；0=只提前关
                                            //   闭搬运、不重用号（二分诊断用）
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    /* 特征流（det_color_feat 直连或 det_feat_top 输出抽头） */
    input  wire        i_valid,
    input  wire [2:0]  i_cid,

    /* OSD 框接口（一帧更新一次，其余时间保持；框 0 在最低位） */
    output wire [N_OUT*48-1:0] o_box_xy,
    output wire [N_OUT*64-1:0] o_box_text,
    output wire [N_OUT*24-1:0] o_box_color,
    output reg         o_frame_done,
    output reg         o_box_toggle
);
    localparam integer LW = (NL <= 64) ? 6 : 8; // 标签位宽（0 号 = LNULL 保留）
    localparam [8:0]   NLW = NL[8:0];       // 标签表深（9bit 口径统一比较）
    localparam [8:0]   NSW = 9'd256;        // scratch 槽位总数（9bit 口径）
    localparam [LW-1:0] LNULL = {LW{1'b0}};
    localparam [47:0] BOX_OFF = {48{1'b1}};
    localparam CLSE = (RECYCLE_EN != 0);    // 回收总闸（0=全旧式行为）

    /* ================= 像素坐标（有效拍推进，帧长严格 IMG_W x IMG_H） ====== */
    reg [11:0] r_x, r_y;
    wire       w_eof   = i_valid && (r_x == IMG_W-1) && (r_y == IMG_H-1);
    wire       w_first = i_valid && (r_x == 12'd0)   && (r_y == 12'd0);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_x <= 12'd0; r_y <= 12'd0;
        end else if (i_valid) begin
            if (r_x == IMG_W-1) begin
                r_x <= 12'd0;
                r_y <= (r_y == IMG_H-1) ? 12'd0 : r_y + 12'd1;
            end else begin
                r_x <= r_x + 12'd1;
            end
        end
    end

    /* ================= live 标签表（方案C：大数组迁 LUTRAM） ==============
     * 每读口一副本（异步读 = FF 同语义），同写地址/数据；无复位——
     * "分配自指先于任何 find3 读"由父指针竞态修复保证，未分配标签
     * 永不被读（closed=1 被 COPY/reaper 跳过）。parent 8 口 = S1/S2
     * 各一条 find3 三级链(3+3) + COPY/burst 翻译各 1。 */
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_0 [0:NL-1];        // S1 find3 第 1 级
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_1 [0:NL-1];        // S1 find3 第 2 级
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_2 [0:NL-1];        // S1 find3 第 3 级
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_3 [0:NL-1];        // S2 find3 第 1 级
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_4 [0:NL-1];        // S2 find3 第 2 级
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_5 [0:NL-1];        // S2 find3 第 3 级
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_6 [0:NL-1];        // COPY 翻译读口
    (* ram_style = "distributed" *)
    reg [LW-1:0]  parent_7 [0:NL-1];        // 关闭 burst 翻译读口
    (* ram_style = "distributed" *)
    reg [17:0]    cnt_0   [0:NL-1];         // S3 读 idm
    (* ram_style = "distributed" *)
    reg [17:0]    cnt_1   [0:NL-1];         // S3 读 idM（合并折算）
    (* ram_style = "distributed" *)
    reg [17:0]    cnt_2   [0:NL-1];         // COPY 读
    (* ram_style = "distributed" *)
    reg [17:0]    cnt_3   [0:NL-1];         // 关闭 burst 读
    (* ram_style = "distributed" *)
    reg [11:0]    mnx_0   [0:NL-1];         // 框坐标：S3 idm / idM / COPY / burst
    (* ram_style = "distributed" *)
    reg [11:0]    mnx_1   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mnx_2   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mnx_3   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxx_0   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxx_1   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxx_2   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxx_3   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mny_0   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mny_1   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mny_2   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mny_3   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxy_0   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxy_1   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxy_2   [0:NL-1];
    (* ram_style = "distributed" *)
    reg [11:0]    mxy_3   [0:NL-1];
    reg [9:0]     lasty   [0:NL-1];         // 最后活跃行（留 FF：合并拍写 idm+idM 两处）
    reg [7:0]     slot_0  [0:NL-1];         // scratch 槽位号：COPY 写址读口
    reg [7:0]     slot_1  [0:NL-1];         //   COPY parent->slot 翻译读口
    reg [7:0]     slot_2  [0:NL-1];         //   burst 写址读口
    reg [7:0]     slot_3  [0:NL-1];         //   burst parent->slot 翻译读口
    reg [0:NL-1]  closed;                   // 留 FF（帧界批量复位+多点写）
    (* ram_style = "distributed" *)
    reg [LW-1:0]  free_st_0 [0:NL-1];       // 空闲标签栈（单读口：S1 弹栈预览）
    reg [7:0]     r_sp;                     // 栈指针（0=空）
    reg [8:0]     ns_cnt;                   // 本帧已配槽位数 = 组件总数（含已关闭）
    reg [15:0]    r_giveup;                 // 分配放弃计数（标签/槽位耗尽探针）
    reg [8:0]     r_alloc;                  // 单调递增分配水位（弹栈分配不递增）

    /* 行缓存：上一行同列的已解析根（异步读，同址先读后写取旧值） */
    reg [LW-1:0] line_lab [0:IMG_W-1];

    /* ================= S0：采样 + 行缓存读 ================================ */
    reg        r_v0;
    reg        r_bin0;
    reg [11:0] r_x0, r_y0;
    reg [LW-1:0] r_up0;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_v0 <= 1'b0; r_bin0 <= 1'b0;
            r_x0 <= 12'd0; r_y0 <= 12'd0; r_up0 <= LNULL;
        end else begin
            r_v0 <= i_valid;
            if (i_valid) begin
                r_bin0 <= (i_cid == WBC_CID);
                r_x0   <= r_x;
                r_y0   <= r_y;
                r_up0  <= line_lab[r_x];    // 上一行同列（旧值）
            end
        end
    end

    /* 槽位 -> 图像坐标换算（-COORD_ADJ，不足则夹 0） */
    function [11:0] dec12;
        input [11:0] v;
        begin
            dec12 = (v >= COORD_ADJ) ? (v - COORD_ADJ) : 12'd0;
        end
    endfunction

    /* S1 侧 find3 三级链（parent 读口 0/1/2，异步读直通） */
    wire [LW-1:0] w_f3a_0 = parent_0[r_up0];
    wire [LW-1:0] w_f3a_1 = parent_1[w_f3a_0];
    wire [LW-1:0] w_f3a_2 = parent_2[w_f3a_1];

    /* ================= S1：up 根解析 ====================================== */
    /* 帧首行（y==0）的 up 强制为空：既是边界条件，也隔断上帧残留/复位 X。
     * 圆形视野掩码（可选）：剔除目镜边缘光晕环与暗角——光晕是蓝紫色的连续
     * 环状连通域，色相恰落在白细胞窗内且外接框近全屏，必须在分类前掩掉。 */
    reg        r_v1;
    reg        r_bin1;
    reg [11:0] r_x1, r_y1;
    reg [LW-1:0] r_up1;

    localparam [11:0] CX = IMG_W/2;
    localparam [11:0] CY = IMG_H/2;
    localparam integer MINWH = (IMG_W < IMG_H) ? IMG_W : IMG_H;
    localparam [31:0] FOV_R2 = (MINWH * FOV_R_PCT / 100) * (MINWH * FOV_R_PCT / 100);
    wire [11:0] w_dx0   = (r_x0 > CX) ? (r_x0 - CX) : (CX - r_x0);
    wire [11:0] w_dy0   = (r_y0 > CY) ? (r_y0 - CY) : (CY - r_y0);
    wire        w_in_fov = (ENABLE_FOV == 1'b0) ||
                           ((w_dx0 * w_dx0 + w_dy0 * w_dy0) <= FOV_R2);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_v1 <= 1'b0; r_bin1 <= 1'b0;
            r_x1 <= 12'd0; r_y1 <= 12'd0; r_up1 <= LNULL;
        end else begin
            r_v1 <= r_v0;
            if (r_v0) begin
                r_bin1 <= r_bin0 && w_in_fov;   /* FOV 掩码：圆外不参与标记 */
                r_x1   <= r_x0;
                r_y1   <= r_y0;
                r_up1  <= ((r_up0 == LNULL) || (r_y0 == 12'd0))
                          ? LNULL : w_f3a_2;
            end
        end
    end

    /* ================= S2：并查集判定（左根 find2 + 分配/合并/沿用） ====== */
    reg        r_v2;
    reg [1:0]  r_op;                        // 0=无 1=新分配 2=合并 3=沿用累加
    reg [LW-1:0] r_idm;                     // 保留根（合并=小根）/新标签/沿用根
    reg [LW-1:0] r_idM;                     // 被吸收的大根（仅合并时有效）
    reg [11:0] r_x2, r_y2;
    reg [LW-1:0] r_run;                     // 当前游程根（下一像素的 left）
    reg        r_fst0, r_fst1;              // 帧首像素标记随流水移位

    /* S2 侧 find3 三级链（parent 读口 3/4/5） */
    wire [LW-1:0] w_f3b_0 = parent_3[r_run];
    wire [LW-1:0] w_f3b_1 = parent_4[w_f3b_0];
    wire [LW-1:0] w_f3b_2 = parent_5[w_f3b_1];
    wire [LW-1:0] w_lf    = w_f3b_2;               // 决策用真实左根
    wire          w_both  = (r_run != LNULL) && (r_up1 != LNULL);
    wire          w_merge = w_both && (w_lf != r_up1);
    /* 合并方向：与旧版一致按标签号比（大号并入小号）。曾试按槽位号
     * （分配时序）比——find3 三级上限常返回半路节点，其槽位恒"老"，
     * 方向恒赢，像素统计反复折进僵死节点的陈旧计数（联仿实测膨胀至
     * 229k px），反而远差于按号比，已废弃。 */
    wire [LW-1:0] w_minid = (w_lf <= r_up1) ? w_lf  : r_up1;
    wire [LW-1:0] w_maxid = (w_lf <= r_up1) ? r_up1 : w_lf;
    wire          w_alloc = (r_run == LNULL) && (r_up1 == LNULL);
    /* 下一个分配 id：帧首像素重置为 1（0 号 = LNULL 保留不用）。
     * 弹栈优先：空闲栈非空取栈顶（回收标签），栈空退回单调递增水位。
     * 边界检查必须用未截断的 w_next_id —— 若用截断后的低位判断，
     * 计数超过 NL 后 id 会回卷，反复踩踏已有组件的统计 */
    wire [8:0]    w_next_id = r_fst1 ? 9'd1 :
                              (CLSE && (POP_EN != 0) && (r_sp != 7'd0)) ?
                              {2'b00, free_st_0[r_sp - 7'd1]} : r_alloc;
    wire          w_alloc_ok = w_alloc && (w_next_id < NLW) && (ns_cnt < NSW);
    wire [LW-1:0] w_root  = !r_bin1                 ? LNULL :
                            w_alloc                  ? (w_alloc_ok ? w_next_id[LW-1:0] : LNULL) :
                            w_merge                  ? w_minid :
                            ((r_run != LNULL) ? w_lf : r_up1);
    /* 操作门控必须含 r_bin1：背景像素左右邻居皆空，w_alloc 恒真，
     * 不加 bin 门控会把整幅背景都当成新组件分配掉 */
    wire          w_op_al = r_bin1 && w_alloc && w_alloc_ok;
    wire          w_op_mg = r_bin1 && w_merge;
    /* 分配在流水中的两拍窗（S1 判定拍 + S3 执行拍）：reaper 在此窗内
     * 不得压栈/弹栈，否则栈顶读数与 r_sp 写回错位 */
    wire          w_al_inflight = (r_v1 && r_bin1 && w_alloc && w_alloc_ok) ||
                                  (r_v2 && (r_op == 2'd1));
    /* parent 统一写口（方案C：分配自指/合并指向二选一，单写位点×8 副本） */
    wire          w_par_we  = r_v1 && (w_op_al || w_op_mg);
    wire [LW-1:0] w_par_wa  = w_op_al ? w_next_id[LW-1:0] : w_maxid;
    wire [LW-1:0] w_par_wd  = w_op_al ? w_next_id[LW-1:0] : w_minid;

    integer si;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_v2 <= 1'b0; r_op <= 2'd0;
            r_idm <= LNULL; r_idM <= LNULL;
            r_x2 <= 12'd0; r_y2 <= 12'd0;
            r_run <= LNULL;
            r_fst0 <= 1'b0; r_fst1 <= 1'b0;
            r_alloc <= 9'd0;
            r_giveup <= 16'd0;
            /* parent 无复位（LUTRAM 无复位语义；分配自指先于读，见方案C） */
        end else begin
            r_fst0 <= w_first;
            r_fst1 <= r_fst0;
            r_v2 <= r_v1;
            if (r_v1) begin
                r_x2 <= r_x1;
                r_y2 <= r_y1;
                r_idm <= w_root;                 // 沿用/合并=小根，分配=新号
                r_idM <= w_op_mg ? w_maxid : LNULL;
                r_op  <= w_op_mg ? 2'd2 :
                         w_op_al ? 2'd1 :
                         (w_root != LNULL) ? 2'd3 : 2'd0;
                r_run <= (r_x1 == IMG_W-1) ? LNULL : w_root;   /* 断行只清携带值 */
                /* 分配水位：帧首像素无条件播种为 1（0 号 = LNULL 保留——
                 * 若帧首是背景则无人分配，水位停在 0，首个 bump 分配会取
                 * 到保留号 0：其 line_lab 写 LNULL 断链、整条游程碎裂，
                 * 2026-10-10 首跑 (671,72) 幽灵组件实证）；只有单调递增
                 * 分配（弹栈落空）才推进水位，回收标签重用不递增 */
                if (r_fst1)
                    r_alloc <= 9'd1;
                else if (w_op_al && ((POP_EN == 0) || (r_sp == 7'd0)))
                    r_alloc <= r_alloc + 9'd1;
                /* 放弃计数：标签表或槽位耗尽（探针用，正常帧应为 0） */
                if (r_bin1 && w_alloc && !w_alloc_ok)
                    r_giveup <= r_giveup + 16'd1;
                /* parent 写集中在 S2 判定拍（单驱动纪律）。分配的自父指针
                 * 必须提前一拍：下一像素的 S2 在本像素 S3 落账前就执行
                 * find3(r_run)——新标签若刚回收，parent[] 里还留着上一世
                 * 的父链，迟一拍写会让游程第二像素延长进已死组件（实测
                 * 首分歧 y=75 x=787）。合并的父指针同样提前，无副作用。 */
                if (w_par_we) begin
                    parent_0[w_par_wa] <= w_par_wd; parent_1[w_par_wa] <= w_par_wd;
                    parent_2[w_par_wa] <= w_par_wd; parent_3[w_par_wa] <= w_par_wd;
                    parent_4[w_par_wa] <= w_par_wd; parent_5[w_par_wa] <= w_par_wd;
                    parent_6[w_par_wa] <= w_par_wd; parent_7[w_par_wa] <= w_par_wd;
                end
            end
        end
    end

    /* ================= S3：统计表写入（分配初始化 / 合并折算 / 累加） ====== */
    wire [17:0] w_cm  = (r_op == 2'd2) ? (cnt_0[r_idm] + cnt_1[r_idM] + 18'd1)
                                        : (cnt_0[r_idm] + 18'd1);
    wire [11:0] w_xn  = (r_x2 < mnx_0[r_idm]) ? r_x2 : mnx_0[r_idm];
    wire [11:0] w_xx  = (r_x2 > mxx_0[r_idm]) ? r_x2 : mxx_0[r_idm];
    wire [11:0] w_yn  = (r_y2 < mny_0[r_idm]) ? r_y2 : mny_0[r_idm];
    wire [11:0] w_yx  = (r_y2 > mxy_0[r_idm]) ? r_y2 : mxy_0[r_idm];
    wire [11:0] w_ax0 = (mnx_0[r_idm] < mnx_1[r_idM]) ? mnx_0[r_idm] : mnx_1[r_idM];
    wire [11:0] w_ax1 = (mxx_0[r_idm] > mxx_1[r_idM]) ? mxx_0[r_idm] : mxx_1[r_idM];
    wire [11:0] w_ay0 = (mny_0[r_idm] < mny_1[r_idM]) ? mny_0[r_idm] : mny_1[r_idM];
    wire [11:0] w_ay1 = (mxy_0[r_idm] > mxy_1[r_idM]) ? mxy_0[r_idm] : mxy_1[r_idM];
    /* live 大数组 LUTRAM 统一写口（方案C：使能/数据按 op 选 mux，单写位点） */
    wire        w_st_we  = r_v2 && (r_op != 2'd0);
    wire [17:0] w_cnt_wd = (r_op == 2'd1) ? 18'd1 : w_cm;
    wire [11:0] w_mnx_wd = (r_op == 2'd1) ? r_x2 :
                           (r_op == 2'd2) ? ((w_ax0 < r_x2) ? w_ax0 : r_x2) : w_xn;
    wire [11:0] w_mxx_wd = (r_op == 2'd1) ? r_x2 :
                           (r_op == 2'd2) ? ((w_ax1 > r_x2) ? w_ax1 : r_x2) : w_xx;
    wire [11:0] w_mny_wd = (r_op == 2'd1) ? r_y2 :
                           (r_op == 2'd2) ? ((w_ay0 < r_y2) ? w_ay0 : r_y2) : w_yn;
    wire [11:0] w_mxy_wd = (r_op == 2'd1) ? r_y2 :
                           (r_op == 2'd2) ? ((w_ay1 > r_y2) ? w_ay1 : r_y2) : w_yx;

    /* ---- reaper 寄存器（声明前置：w_rc7fire/S3 块前向引用安全） ---------
     * r_rp 扫描 walker（标签号 1..NL-1）；r_rc 0=巡检 1..7=关闭 burst；
     * r_fini 帧界批量初始化脉冲（COPY 完成后由解析 FSM 置位，S3 块消费） */
    reg [7:0]  r_rp;                         // 扫描 walker（标签号 1..NL-1）
    reg [3:0]  r_rc;                         // 0=巡检 1..7=关闭 burst（6 数组+落账）
    reg [LW-1:0] r_rL;                       // burst 目标标签
    reg [7:0]  r_rslot;                      // burst 目标槽位
    reg        r_fini;                       // 帧界批量初始化脉冲

    /* reaper 关闭 burst 末拍（live 侧落账：closed 置位 + 压栈）。
     * 与分配窗互斥（w_al_inflight 含 S3 执行拍）；fini 批量初始化拍互斥
     * （reaper 在解析期本就停摆，此条件防两分支同时写 r_sp）。 */
    wire w_rc7fire = CLSE && (r_rc == 4'd7) && !w_al_inflight && !r_fini;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            /* 方案C：cnt/框坐标/parent/slot/free_st 迁 LUTRAM 无复位；
             * lasty/closed 留 FF 保留复位 */
            for (si = 0; si < NL; si = si + 1) begin
                lasty[si] <= 10'h3ff;
                closed[si] <= CLSE;
            end
            r_sp <= 8'd0; ns_cnt <= 9'd0;
        end else begin
            if (r_v2 && (r_op != 2'd0)) begin
                /* live 大数组 LUTRAM 写（单写位点×每副本；数据见 w_*_wd mux） */
                cnt_0[r_idm] <= w_cnt_wd;  cnt_1[r_idm] <= w_cnt_wd;
                cnt_2[r_idm] <= w_cnt_wd;  cnt_3[r_idm] <= w_cnt_wd;
                mnx_0[r_idm] <= w_mnx_wd;  mnx_1[r_idm] <= w_mnx_wd;
                mnx_2[r_idm] <= w_mnx_wd;  mnx_3[r_idm] <= w_mnx_wd;
                mxx_0[r_idm] <= w_mxx_wd;  mxx_1[r_idm] <= w_mxx_wd;
                mxx_2[r_idm] <= w_mxx_wd;  mxx_3[r_idm] <= w_mxx_wd;
                mny_0[r_idm] <= w_mny_wd;  mny_1[r_idm] <= w_mny_wd;
                mny_2[r_idm] <= w_mny_wd;  mny_3[r_idm] <= w_mny_wd;
                mxy_0[r_idm] <= w_mxy_wd;  mxy_1[r_idm] <= w_mxy_wd;
                mxy_2[r_idm] <= w_mxy_wd;  mxy_3[r_idm] <= w_mxy_wd;
            end
            if (r_v2) begin
                if (r_op == 2'd1) begin                 // 新分配：当前像素即首像素
                    lasty[r_idm] <= r_y2;
                    slot_0[r_idm] <= ns_cnt[7:0];       // 配新槽位（单调递增）
                    slot_1[r_idm] <= ns_cnt[7:0];
                    slot_2[r_idm] <= ns_cnt[7:0];
                    slot_3[r_idm] <= ns_cnt[7:0];
                    ns_cnt <= ns_cnt + 9'd1;
                    closed[r_idm] <= 1'b0;              // 复活：可参与关闭判定
                    if (CLSE && (POP_EN != 0) && (r_sp != 7'd0))
                        r_sp <= r_sp - 7'd1;            // 弹栈（w_next_id 已取栈顶）
                end else if (r_op == 2'd2) begin        // 合并：大根并入小根 + 当前像素
                    /* 被吸收大根的 lasty 也刷新到合并行：它在合并点之前的
                     * 游程前缀仍以本标签写在本行 line_lab 里（幽影），要到
                     * 下一行才被读掉——关闭必须等幽影消费完（lasty=合并行
                     * => 关闭于合并行+2），否则回收后的重分配会接住旧引用，
                     * 把无关组件焊进新组件（首跑 4549px 巨框实证） */
                    lasty[r_idm] <= r_y2;
                    lasty[r_idM] <= r_y2;
                end else if (r_op == 2'd3) begin        // 沿用：累加当前像素
                    lasty[r_idm] <= r_y2;
                end
            end else if (r_fini) begin
                /* 帧界批量初始化（COPY 之后、下一帧首个分配之前，v-blank 内）：
                 * 全体置"未分配/已关闭"，lasty 置全 1（永不满足关闭条件），
                 * 槽位计数与空闲栈清空——下一帧从槽位 0、单调分配重新开始 */
                for (si = 0; si < NL; si = si + 1) begin
                    closed[si] <= CLSE;
                    lasty[si]  <= 10'h3ff;
                end
                ns_cnt <= 9'd0;
                r_sp   <= 7'd0;
            end
            if (w_rc7fire) begin
                closed[r_rL] <= 1'b1;                   // 标签退役
                free_st_0[r_sp[LW-1:0]] <= r_rL;      // 压入空闲栈（LUTRAM 单写口）
                r_sp <= r_sp + 7'd1;
            end
        end
    end

    /* 行缓存写（当前像素的根；出类/放弃写空，阻断向下一行泄漏） */
    always @(posedge i_clk) begin
        if (r_v2)
            line_lab[r_x2] <= (r_op == 2'd0) ? LNULL : r_idm;
    end

    /* ================= 帧末解析（scratch 副本上，不碰 live 表） =========== */
    /* 槽位域：scratch 以 slot（帧内单调分配的槽位号）为地址，parent 存的
     * 是槽位号（COPY/关闭 burst 时从标签号域翻译）；根判定 sparent[s]==s。
     * 槽位帧内不复用 => 先关闭组件的数据一直保留，扫描边界 s_amax=ns_cnt
     * 恰好覆盖本帧全部组件。
     * 【方案 B：scratch 七数组迁 ERAM（2026-10-10）】回收引入槽位间接寻址
     * （写址来自 slot[] 读出）+ 多写位点，TD 拒绝把 distributed 阵列推断为
     * LUTRAM（实测 323% 爆片：dram lut 2728→1584、det_wbc20 LUT 11k→25.9k）。
     * ERAM 为硬原语不挑写法：七数组各配 A/B 两副本（合并扫描需同拍读 i/j
     * 两个地址），每副本单写口+单同步读口——经典 SDP 推断形状，写口五源
     * （COPY/关闭 burst/J_WR/B3/M_APPLY）汇到每数组唯一写位点。
     * 同步读 1 拍延迟由解析 FSM 地址预置拍吸收：COPY 1 拍/项不变、
     * JUMP 3→4 拍/项（嵌套读拆两级）、BSUM 1→3 拍/项、合并 1→2 拍/对、
     * argmax 1→2 拍/项，总拍数仍为万拍量级，帧间隙充裕。
     * 关闭搬运保留基线 7 拍 burst 节奏（rc1..rc6 分拍写六数组、rc7 落账），
     * 内部状态与基线逐位一致。s_dead/s_taken 为按位写位向量，留 FF。
     * dout 无复位：首帧未写槽位为 X 与旧版 distributed 行为一致
     * （s_amax 边界保证有效槽位必已写）。 */
    (* ram_style = "block" *)
    reg [7:0]    sparent_a [0:NS-1];        // 并查集父指针（槽位域）A 副本
    (* ram_style = "block" *)
    reg [7:0]    sparent_b [0:NS-1];        //   B 副本（合并扫描 j 侧读口）
    (* ram_style = "block" *)
    reg [17:0]   scnt_a   [0:NS-1];
    (* ram_style = "block" *)
    reg [17:0]   scnt_b   [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mnx_a  [0:NS-1];         // 簇并集框（合并时取并集）
    (* ram_style = "block" *)
    reg [11:0]   s_mnx_b  [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mxx_a  [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mxx_b  [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mny_a  [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mny_b  [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mxy_a  [0:NS-1];
    (* ram_style = "block" *)
    reg [11:0]   s_mxy_b  [0:NS-1];
    (* ram_style = "block" *)
    reg [17:0]   s_bsum_a [0:NS-1];         // 分件框面积和（分件填充率分母）
    (* ram_style = "block" *)
    reg [17:0]   s_bsum_b [0:NS-1];
    reg [NS-1:0] s_dead;                    // 已被吸收的组件（位向量留 FF）
    reg [NS-1:0] s_taken;
    reg [8:0]    s_amax;
    /* 同步读数据口（每拍刷新 = mem[ra]） */
    reg [7:0]    d_par_a,  d_par_b;
    reg [17:0]   d_cnt_a,  d_cnt_b;
    reg [11:0]   d_x0_a, d_x1_a, d_y0_a, d_y1_a;
    reg [11:0]   d_x0_b, d_x1_b, d_y0_b, d_y1_b;
    reg [17:0]   d_bs_a,  d_bs_b;

    reg [4:0]  r_fst;                        // 0 IDLE 1 COPY 2 J_A1 3 J_A2 4 J_A3
                                             // 5 J_WR 6 B1 7 B2 8 B3 9 M_EV
                                             // 10 M_WT 11 M_APPLY 12 RSW 13 RSC
                                             // 14 RP1 15 RP2 16 RCM 17 DONE
    reg [7:0]  r_scan;
    reg [4:0]  r_round;
    reg [7:0]  r_best;
    reg [17:0] r_bestc;
    reg        r_found;
    reg [7:0]  r_eff;                        // RCM 拍要提交的簇号（槽位域）
    reg [7:0]  r_sidx;                       // COPY/BSUM 串行索引 / JUMP 条目号
    reg [7:0]  r_p;                          // JUMP 串行压平的父指针暂存
    reg [7:0]  r_mi, r_mj;                   // 合并扫描指针（i 发起，j 被并入）
    reg [3:0]  r_pass;                       // 先作压平轮数(0..2)，后作合并扫描轮数
    reg        r_mchg;                       // 本轮发生过合并
    reg [17:0] r_m_cnt;                      // 合并值暂存：M_EV 读算 -> M_APPLY 写回
    reg [11:0] r_m_x0, r_m_x1, r_m_y0, r_m_y1;
    reg [17:0] r_m_bsum;
    reg [17:0] r_prod;                       // BSUM 乘积暂存（B2 算 B3 写）
    reg [11:0] r_c_bw, r_c_bh;               // R_PREP 暂存：提交簇的框宽高
    reg [17:0] r_c_cnt, r_c_bsum;            //   及像素和/分件面积和
    reg [11:0] r_c_x0, r_c_x1, r_c_y0, r_c_y1; //   及框坐标（RCM 不再读表）

    /* ---- reaper：后台关闭扫描（1 标签/拍 + 7 拍关闭 burst） --------------
     * 门控：解析 FSM 空闲（r_fst==0，统一写口在像素期归 burst 独占）、
     * 行首 4 拍后、非末行、分配两拍窗之外。候选条件 lasty+2<=当前行：
     * 4 连通下该组件已不可能再收到像素。burst rc1..rc6 分拍写六数组
     * （经统一写口），rc7 落账 closed/压栈——与基线逐拍同构。 */
    wire w_rp_gate = CLSE && (r_fst == 4'd0) && r_v2 && (r_x2 >= 12'd4) &&
                     (r_y0 != (IMG_H-1)) && !w_al_inflight;
    wire w_rp_cand = w_rp_gate && (r_rc == 4'd0) && (r_rp != 7'd0) &&
                     !closed[r_rp] &&
                     (({2'b00, lasty[r_rp]} + 12'd2) <= r_y0);

    reg [47:0] r_box  [0:N_OUT-1];
    reg        r_eof1, r_eof2, r_eof3, r_eof4;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_eof1 <= 1'b0; r_eof2 <= 1'b0; r_eof3 <= 1'b0; r_eof4 <= 1'b0;
        end else begin
            r_eof1 <= w_eof; r_eof2 <= r_eof1;
            r_eof3 <= r_eof2; r_eof4 <= r_eof3;   // eof+4 = 末像素统计已写完
        end
    end

    /* ---- 簇合并：资格与相交判定（ERAM dout 上判定，M_EV 拍消费） --------
     * 只有种子（cnt>=SEED_MIN）参与簇：发起方与被并入方都必须是种子——
     * 稀疏碎块若被并入会把簇的填充率拉低到阈值下（181408 实测），
     * 直接忽略之；碎块自身也因不足种子而下不了框，与旧行为一致。 */
    wire w_i_ok = (r_mi < s_amax) && (d_par_a == r_mi) &&
                  !s_dead[r_mi] && (d_cnt_a >= SEED_MIN);
    wire w_j_ok = (r_mj < s_amax) && (d_par_b == r_mj) &&
                  !s_dead[r_mj] && (d_cnt_b >= SEED_MIN);
    wire [12:0] w_axg1 = {1'b0, d_x1_a} + {1'b0, MERGE_GAP};
    wire [12:0] w_ayg1 = {1'b0, d_y1_a} + {1'b0, MERGE_GAP};
    wire [12:0] w_bxg1 = {1'b0, d_x1_b} + {1'b0, MERGE_GAP};
    wire [12:0] w_byg1 = {1'b0, d_y1_b} + {1'b0, MERGE_GAP};
    /* 与 Python 镜像逐项一致的正向形式：j 框落在 i 框双向扩 MERGE_GAP 内
     * （等价于"扩框相交"，无减法无下溢） */
    wire w_m_ov = ({1'b0, d_x0_b} <= w_axg1) &&
                  ({1'b0, d_x0_a} <= w_bxg1) &&
                  ({1'b0, d_y0_b} <= w_ayg1) &&
                  ({1'b0, d_y0_a} <= w_byg1);
    wire [11:0] w_ux0 = (d_x0_a < d_x0_b) ? d_x0_a : d_x0_b;
    wire [11:0] w_ux1 = (d_x1_a > d_x1_b) ? d_x1_a : d_x1_b;
    wire [11:0] w_uy0 = (d_y0_a < d_y0_b) ? d_y0_a : d_y0_b;
    wire [11:0] w_uy1 = (d_y1_a > d_y1_b) ? d_y1_a : d_y1_b;
    wire [12:0] w_uw  = {1'b0, w_ux1} - {1'b0, w_ux0} + 13'd1;
    wire [12:0] w_uh  = {1'b0, w_uy1} - {1'b0, w_uy0} + 13'd1;
    wire w_m_ok = w_i_ok && w_j_ok && w_m_ov &&
                  (w_uw <= MERGE_MAXWH) && (w_uh <= MERGE_MAXWH);

    /* 轮次扫描：每拍看一个槽位（scratch 上，与逐像素通路无任何共享）。
     * 选框拆两拍：R_SCAN 只做候选比较（得到 r_eff），R_COMMIT 再读簇统计
     * 做几何过滤并写框 —— 避免 cand->eff_best->读->乘法 的单拍长链。 */
    wire w_cand   = (r_scan < s_amax) &&
                    (d_par_a == r_scan) &&
                    (d_cnt_a >= MIN_AREA) && !s_taken[r_scan] && !s_dead[r_scan];
    wire w_better = w_cand && (!r_found || (d_cnt_a > r_bestc));
    wire w_last   = (r_scan >= s_amax - 9'd1) || (r_scan == 8'd255);
    /* 本拍候选若更好，提交时必须用它本身 —— 否则扫描末位置的赢家会被丢掉 */
    wire [7:0] w_eff_best = w_better ? r_scan : r_best;
    /* 几何过滤（R_COMMIT 拍逐簇判定，不动逐像素通路）。统计在 R_PREP 拍
     * 从 LUTRAM 读出寄存，本拍只剩乘法+比较——避免 读->减->乘->比较 单拍链：
     *   整框填充率 = 簇像素和 / 并集框面积 ×100 ≥ COMPACT_PCT
     *   分件填充率 = 簇像素和 / 分件框面积和 ×100 ≥ COMPACT_PCT（二选一即可；
     *   环形/花斑细胞簇靠分件支路救回，光晕环与 RBC 细链两支路都过不了）
     *   面积上限 = 簇像素和 ≤ 整帧的 MAX_AREA_PCT%（超大组件丢弃） */
    wire [25:0] w_barea = r_c_bw * r_c_bh;
    wire [25:0] w_c100  = r_c_cnt * 7'd100;
    wire [25:0] w_parea = {8'd0, r_c_bsum};
    localparam [17:0] MAXLIM = MAX_AREA_PCT * (IMG_W * IMG_H) / 100;
    wire w_geom_ok = ((w_c100 >= COMPACT_PCT * w_barea) ||
                      (w_c100 >= COMPACT_PCT * w_parea)) &&
                     (r_c_cnt <= MAXLIM);

    integer fi;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_fst <= 5'd0; r_scan <= 8'd0;
            r_round <= 5'd0; r_best <= 8'd0; r_bestc <= 18'd0;
            r_found <= 1'b0;
            r_eff <= 8'd0;
            r_sidx <= 8'd0; r_p <= 8'd0;
            r_mi <= 8'd0; r_mj <= 8'd1;
            r_pass <= 4'd0; r_mchg <= 1'b0;
            r_m_cnt <= 18'd0;
            r_m_x0 <= 12'd0; r_m_x1 <= 12'd0; r_m_y0 <= 12'd0; r_m_y1 <= 12'd0;
            r_m_bsum <= 18'd0;
            r_prod <= 18'd0;
            r_c_bw <= 12'd0; r_c_bh <= 12'd0;
            r_c_cnt <= 18'd0; r_c_bsum <= 18'd0;
            r_c_x0 <= 12'd0; r_c_x1 <= 12'd0; r_c_y0 <= 12'd0; r_c_y1 <= 12'd0;
            r_fini <= 1'b0;
            r_rp <= 8'd1; r_rc <= 4'd0; r_rL <= {LW{1'b0}}; r_rslot <= 8'd0;
            s_taken <= {(NS){1'b0}}; s_dead <= {(NS){1'b0}}; s_amax <= 9'd0;
            o_frame_done <= 1'b0; o_box_toggle <= 1'b0;
            for (fi = 0; fi < N_OUT; fi = fi + 1) r_box[fi] <= BOX_OFF;
        end else begin
            o_frame_done <= 1'b0;
            /* ---- reaper：后台关闭扫描（与解析 FSM 同块=单写口纪律） -------
             * cand 拍锁存目标，rc1..rc6 经统一写口分拍写六数组（数据源与
             * 基线同拍同值），rc7 落账 closed/压栈。 */
            if (w_rp_cand) begin
                r_rL    <= r_rp[LW-1:0];
                r_rslot <= slot_2[r_rp];
                r_rc    <= 4'd1;
            end else if (r_rc != 4'd0) begin
                r_rc <= r_rc + 4'd1;
                case (r_rc)
                4'd7: if (!w_al_inflight && !r_fini) begin
                          r_rc <= 4'd0;
                          r_rp <= (r_rL == (NL-1)) ? 8'd1 : (r_rL + 8'd1);
                      end
                default: if (r_rc > 4'd7) r_rc <= 4'd0;  // 越程保险（基线同款兜底）
                endcase
            end else if (w_rp_gate) begin
                r_rp <= (r_rp == (NL-1)) ? 8'd1 : (r_rp + 8'd1);
            end
            case (r_fst)
            5'd0: if (r_eof4) begin                  // 帧 N 统计已定 -> 进入解析
                s_taken <= {(NS){1'b0}};
                s_dead  <= {(NS){1'b0}};
                for (fi = 0; fi < N_OUT; fi = fi + 1) r_box[fi] <= BOX_OFF;
                if (ns_cnt == 9'd0) begin
                    /* 空帧（全图无 WBC 像素）：无组件可解析，直接收尾，
                     * 同时照常触发帧界初始化（栈/槽位/lasty 复位） */
                    r_fini <= 1'b1;
                    r_fst  <= 5'd17;
                end else begin
                    s_amax <= ns_cnt;                // 扫描边界 = 本帧组件总数
                    r_sidx <= 8'd0;
                    r_pass <= 4'd0;
                    r_fst  <= 5'd1;
                end
            end
            /* ---- COPY：逐项 live -> scratch（写经统一写口，1 拍/项不变） ----
             * 只搬未关闭标签（关闭件已被 burst 提前搬到各自槽位，不可覆写）；
             * parent 标签号->槽位号翻译在 w_wd_par。 */
            5'd1: begin
                if (r_sidx == NL - 1) begin
                    r_sidx <= 8'd0;
                    r_pass <= 4'd0;
                    r_fini <= 1'b1;                  // 帧界初始化（下一帧状态）
                    r_fst  <= 5'd2;                  // -> 压平
                end else
                    r_sidx <= r_sidx + 8'd1;
            end
            /* ---- JUMP：串行压平，同步读下 4 拍/项（共 3 轮）----
             * A1 预址(si) -> A2 取父 p -> A3 预址(p) -> WR 写回 mem[si]<=mem[p]
             * 并推进。父链指向更早分配的槽位，升序遍历途中读到的是已压平
             * 新值，收敛后全员指向根（与旧并行写法同一不动点）。 */
            5'd2: begin                              // J_A1：地址已呈 (r_sidx)
                r_fini <= 1'b0;                      // fini 单拍脉冲，到 JUMP 即清
                r_fst  <= 5'd3;
            end
            5'd3: begin                              // J_A2：dout=mem[si] -> p
                r_p  <= d_par_a;
                r_fst <= 5'd4;
            end
            5'd4: begin                              // J_A3：地址切到 r_p
                r_fst <= 5'd5;
            end
            5'd5: begin                              // J_WR：dout=mem[p]，写回+推进
                if (r_sidx == NS - 1) begin
                    if (r_pass == 2'd2) begin
                        r_sidx <= 8'd0;
                        r_fst  <= 5'd6;              // 压平完成 -> BSUM
                    end else begin
                        r_pass <= r_pass + 4'd1;
                        r_sidx <= 8'd0;
                        r_fst  <= 5'd2;
                    end
                end else begin
                    r_sidx <= r_sidx + 8'd1;
                    r_fst  <= 5'd2;
                end
            end
            /* ---- BSUM：分件框面积和，3 拍/项（预址/取数算积/写回） ------ */
            5'd6: begin                              // B1：地址已呈 (r_sidx)
                r_fst <= 5'd7;
            end
            5'd7: begin                              // B2：dout 有效，算积
                r_prod <= (d_x1_a - d_x0_a + 12'd1) * (d_y1_a - d_y0_a + 12'd1);
                r_fst  <= 5'd8;
            end
            5'd8: begin                              // B3：写回 + 推进
                if (r_sidx == NS - 1) begin
                    r_fst <= 5'd10;                  // -> 合并（先 M_WT 稳读）
                    r_mi <= 8'd0; r_mj <= 8'd1;
                    r_pass <= 4'd0; r_mchg <= 1'b0;
                end else begin
                    r_sidx <= r_sidx + 8'd1;
                    r_fst  <= 5'd6;
                end
            end
            /* ---- 簇合并：M_EV 在 dout 上判定；推进拍改指针后过 M_WT 稳一拍
             * 再判；合并经 M_APPLY 写回后回 M_EV 重查同对（j 已死会前进），
             * 判定只依赖 s_dead（FF 即时可见）与未变的父指针，与旧异步读
             * 同一结果。 ---- */
            5'd9: begin                              // M_EV
                if (w_m_ok) begin
                    r_m_cnt  <= d_cnt_a + d_cnt_b;
                    r_m_x0   <= w_ux0; r_m_x1 <= w_ux1;
                    r_m_y0   <= w_uy0; r_m_y1 <= w_uy1;
                    r_m_bsum <= d_bs_a + d_bs_b;
                    r_fst <= 5'd11;
                end else if (r_mj < s_amax - 9'd1) begin
                    r_mj <= r_mj + 8'd1;
                    r_fst <= 5'd10;
                end else if (r_mi < s_amax - 8'd1) begin
                    r_mi <= r_mi + 8'd1;
                    r_mj <= r_mi + 8'd2;
                    r_fst <= 5'd10;
                end else if (r_mchg && (r_pass != 4'd15)) begin
                    r_pass <= r_pass + 4'd1;         // 本轮有合并 -> 再扫一轮
                    r_mi <= 8'd0; r_mj <= 8'd1; r_mchg <= 1'b0;
                    r_fst <= 5'd10;
                end else begin                       // 合并定案 -> 进入选框
                    r_fst <= 5'd12; r_round <= 5'd0;
                    r_scan <= 8'd0; r_found <= 1'b0; r_bestc <= 18'd0;
                end
            end
            5'd10: begin                             // M_WT：等 dout 稳定
                r_fst <= 5'd9;
            end
            5'd11: begin                             // M_APPLY：写经统一写口，
                s_dead[r_mj] <= 1'b1;                // 位向量直写（FF）
                r_mchg <= 1'b1;
                r_fst <= 5'd9;                       // 回 M_EV 重查同对
            end
            /* ---- argmax 扫描：2 拍/项（RSW 预址 -> RSC 判定推进） -------- */
            5'd12: begin                             // RSW
                r_fst <= 5'd13;
            end
            5'd13: begin                             // RSC
                if (w_better) begin
                    r_best  <= r_scan;
                    r_bestc <= d_cnt_a;
                    r_found <= 1'b1;
                end
                if (w_last) begin
                    if (r_found || w_cand) begin
                        s_taken[w_eff_best] <= 1'b1;
                        r_eff <= w_eff_best;         // 赢家交给 RP/RCM
                        r_fst <= 5'd14;
                    end else begin
                        r_fst  <= 5'd17;             // 无更多候选，余槽保持全 F
                    end
                end else begin
                    r_scan <= r_scan + 8'd1;
                    r_fst  <= 5'd12;
                end
            end
            5'd14: begin                             // RP1：地址切到 r_eff
                r_fst <= 5'd15;
            end
            5'd15: begin                             // RP2：dout 有效，全量寄存
                r_c_bw   <= d_x1_a - d_x0_a + 12'd1;
                r_c_bh   <= d_y1_a - d_y0_a + 12'd1;
                r_c_cnt  <= d_cnt_a;
                r_c_bsum <= d_bs_a;
                r_c_x0   <= d_x0_a; r_c_x1 <= d_x1_a;
                r_c_y0   <= d_y0_a; r_c_y1 <= d_y1_a;
                r_fst    <= 5'd16;
            end
            5'd16: begin                             // RCM：几何过滤 + 写框
                if (w_geom_ok)
                    r_box[r_round] <= {dec12(r_c_x0), dec12(r_c_y0),
                                       dec12(r_c_x1), dec12(r_c_y1)};
                /* 未过几何过滤的簇放弃，对应槽保持全 F */
                r_round <= r_round + 5'd1;
                r_scan  <= 8'd0;
                r_found <= 1'b0; r_bestc <= 18'd0;
                r_fst   <= (r_round == N_OUT-1) ? 5'd17 : 5'd12;
            end
            5'd17: begin                             // 锁存完成：握手脉冲
                o_frame_done <= 1'b1;
                o_box_toggle <= ~o_box_toggle;
                r_fini <= 1'b0;                      // 空帧路径：脉冲在此收尾
                r_fst <= 5'd0;
            end
            default: r_fst <= 5'd0;
            endcase
        end
    end

    /* ---- scratch 统一写口（七数组×2 副本；每数组全文件唯一写位点） -------
     * 写源互斥：reaper burst 仅 r_fst==0（rc1..rc6 分拍），FSM 写仅非 0。
     * COPY 写 6 数组@slot[r_sidx]（bsum 不拷贝，BSUM 阶段现算）；
     * burst rc1..rc6 分拍写 6 数组@r_rslot（数据源/拍点与基线一致）；
     * J_WR 写 parent@r_sidx；B3 写 bsum@r_sidx；M_APPLY 写 6 数组@r_mi。 */
    /* live 表 LUTRAM 读口（方案C）：COPY/burst 数据暂存的源 */
    wire [LW-1:0] w_par_c  = parent_6[r_sidx];  // COPY：parent 读口 6
    wire [7:0]    w_slot_aS = slot_0[r_sidx];   // COPY：scratch 写址
    wire [7:0]    w_slot_pS = slot_1[w_par_c];  // COPY：parent->slot 翻译
    wire [LW-1:0] w_par_r  = parent_7[r_rL];    // burst：parent 读口 7
    wire [7:0]    w_slot_aR = slot_2[r_rp];     // burst：scratch 写址
    wire [7:0]    w_slot_pR = slot_3[w_par_r];  // burst：parent->slot 翻译
    wire [17:0]   w_cnt_rL = cnt_3[r_rL];       // burst：cnt 读口 3
    wire [17:0]   w_cnt_sS = cnt_2[r_sidx];     // COPY：cnt 读口 2
    wire [11:0]   w_x0_rL = mnx_3[r_rL], w_x1_rL = mxx_3[r_rL];
    wire [11:0]   w_y0_rL = mny_3[r_rL], w_y1_rL = mxy_3[r_rL];
    wire [11:0]   w_x0_sS = mnx_2[r_sidx], w_x1_sS = mxx_2[r_sidx];
    wire [11:0]   w_y0_sS = mny_2[r_sidx], w_y1_sS = mxy_2[r_sidx];
    wire        w_rp_wen  = (r_fst == 5'd0) && (r_rc != 4'd0) && (r_rc <= 4'd6);
    wire        w_cpy_go  = (r_fst == 5'd1) && !closed[r_sidx];
    wire [7:0]  w_wa = w_rp_wen ? r_rslot :
                       w_cpy_go  ? w_slot_aS :
                       (r_fst == 5'd11) ? r_mi : r_sidx;
    wire [7:0]  w_wd_par = w_rp_wen ? ((w_par_r == r_rL) ? r_rslot : w_slot_pR) :
                           w_cpy_go  ? w_slot_pS :
                           d_par_a;            // J_WR：压平值（=mem[r_p] 同步读出）
    wire [17:0] w_wd_cnt = w_rp_wen ? w_cnt_rL  : w_cpy_go ? w_cnt_sS  : r_m_cnt;
    wire [11:0] w_wd_x0  = w_rp_wen ? w_x0_rL   : w_cpy_go ? w_x0_sS   : r_m_x0;
    wire [11:0] w_wd_x1  = w_rp_wen ? w_x1_rL   : w_cpy_go ? w_x1_sS   : r_m_x1;
    wire [11:0] w_wd_y0  = w_rp_wen ? w_y0_rL   : w_cpy_go ? w_y0_sS   : r_m_y0;
    wire [11:0] w_wd_y1  = w_rp_wen ? w_y1_rL   : w_cpy_go ? w_y1_sS   : r_m_y1;
    wire [17:0] w_wd_bs  = (r_fst == 5'd8) ? r_prod : r_m_bsum;
    wire w_we_par = (w_rp_wen && (r_rc == 4'd1)) || w_cpy_go || (r_fst == 5'd5);
    wire w_we_cnt = (w_rp_wen && (r_rc == 4'd2)) || w_cpy_go || (r_fst == 5'd11);
    wire w_we_x0  = (w_rp_wen && (r_rc == 4'd3)) || w_cpy_go || (r_fst == 5'd11);
    wire w_we_x1  = (w_rp_wen && (r_rc == 4'd4)) || w_cpy_go || (r_fst == 5'd11);
    wire w_we_y0  = (w_rp_wen && (r_rc == 4'd5)) || w_cpy_go || (r_fst == 5'd11);
    wire w_we_y1  = (w_rp_wen && (r_rc == 4'd6)) || w_cpy_go || (r_fst == 5'd11);
    wire w_we_bs  = (r_fst == 5'd8) || (r_fst == 5'd11);

    /* 读地址：A 口服务单地址读者（JUMP/BSUM/argmax/R_PREP）+ 合并 i 侧；
     * B 口专服务合并 j 侧。状态互斥无冲突。 */
    wire [7:0] w_raA = (r_fst == 5'd9 || r_fst == 5'd10 || r_fst == 5'd11) ? r_mi :
                       (r_fst == 5'd4)  ? r_p :
                       (r_fst == 5'd12 || r_fst == 5'd13) ? r_scan :
                       (r_fst == 5'd14 || r_fst == 5'd15 || r_fst == 5'd16) ? r_eff :
                       r_sidx;
    wire [7:0] w_raB = r_mj;

    /* ---- ERAM 阵列（每数组单写位点+单同步读口；A/B 同写异读） ------------ */
    always @(posedge i_clk) begin
        if (w_we_par) sparent_a[w_wa] <= w_wd_par;
        d_par_a <= sparent_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_par) sparent_b[w_wa] <= w_wd_par;
        d_par_b <= sparent_b[w_raB];
    end
    always @(posedge i_clk) begin
        if (w_we_cnt) scnt_a[w_wa] <= w_wd_cnt;
        d_cnt_a <= scnt_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_cnt) scnt_b[w_wa] <= w_wd_cnt;
        d_cnt_b <= scnt_b[w_raB];
    end
    always @(posedge i_clk) begin
        if (w_we_x0) s_mnx_a[w_wa] <= w_wd_x0;
        d_x0_a <= s_mnx_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_x0) s_mnx_b[w_wa] <= w_wd_x0;
        d_x0_b <= s_mnx_b[w_raB];
    end
    always @(posedge i_clk) begin
        if (w_we_x1) s_mxx_a[w_wa] <= w_wd_x1;
        d_x1_a <= s_mxx_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_x1) s_mxx_b[w_wa] <= w_wd_x1;
        d_x1_b <= s_mxx_b[w_raB];
    end
    always @(posedge i_clk) begin
        if (w_we_y0) s_mny_a[w_wa] <= w_wd_y0;
        d_y0_a <= s_mny_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_y0) s_mny_b[w_wa] <= w_wd_y0;
        d_y0_b <= s_mny_b[w_raB];
    end
    always @(posedge i_clk) begin
        if (w_we_y1) s_mxy_a[w_wa] <= w_wd_y1;
        d_y1_a <= s_mxy_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_y1) s_mxy_b[w_wa] <= w_wd_y1;
        d_y1_b <= s_mxy_b[w_raB];
    end
    always @(posedge i_clk) begin
        if (w_we_bs) s_bsum_a[w_wa] <= w_wd_bs;
        d_bs_a <= s_bsum_a[w_raA];
    end
    always @(posedge i_clk) begin
        if (w_we_bs) s_bsum_b[w_wa] <= w_wd_bs;
        d_bs_b <= s_bsum_b[w_raB];
    end

    /* ================= 输出打包（框 k 在 [k*48 +: 48]，全 F = 关闭） ====== */
    genvar g;
    generate
        for (g = 0; g < N_OUT; g = g + 1) begin : g_box
            assign o_box_xy[g*48 +: 48] = r_box[g];
        end
    endgenerate

    /* 槽号 -> "WBC-01  ".."WBC-10  "（最左字符在最高字节，全在 OSD 字库内） */
    function [63:0] txt_of;
        input [4:0] k;
        reg   [7:0] tens, ones;
        begin
            if (k >= 5'd9) begin
                tens = 8'h31;                        // '1'
                ones = (k == 5'd19) ? 8'h30 : (8'h30 + k - 5'd9);
            end else begin
                tens = 8'h30;                        // '0'
                ones = 8'h30 + k + 5'd1;
            end
            txt_of = {8'h57, 8'h42, 8'h43, 8'h2d, tens, ones, 8'h20, 8'h20};
        end
    endfunction

    generate
        for (g = 0; g < N_OUT; g = g + 1) begin : g_txt
            assign o_box_text[g*64 +: 64]  = txt_of(g[4:0]);
            assign o_box_color[g*24 +: 24] = BOX_COLOR;
        end
    endgenerate

endmodule
