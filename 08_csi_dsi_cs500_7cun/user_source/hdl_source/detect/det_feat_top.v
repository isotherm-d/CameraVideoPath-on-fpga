/*
 * ============================================================================
 * det_feat_top —— 颜色/形状特征提取顶层（扩展要求 2：目标检测与识别）
 *
 * 赛题推荐链路：
 *     MIPI 输入 → ISP 预处理 → 【颜色/形状特征提取 = 本模块】→ 阈值判定
 *     → 连通域/坐标计算 → OSD 结果叠加 → HDMI 显示（DDR2 帧缓存）
 *
 * 一条 RGB888 像素流进来，o_valid 有效时同拍输出该像素的全部特征：
 *
 *   颜色（det_color_feat）：o_hue / o_sat / o_val / o_cid
 *   形状（det_shape_feat）：o_edge / o_mag  / o_dir
 *   对齐像素              ：o_rgb —— 与特征同一像素的原图颜色，
 *                           供下游做检测框/OSD 叠加时直接取用。
 *
 * ---------------------------------------------------------------------------
 * 【对齐约定（重要）】形状特征需要 3x3 窗口，窗口由 imgproc_win3x3 生成，
 * 窗口中心 p11 = 源图坐标 (x-1,y-1)（流式 3x3 的固有延迟，见
 * imgproc_win3x3.v 文件头）。本模块把颜色路也接到同一个窗口的中心像素
 * p11 上，再补齐两路的拍数差 —— 所以 o_valid 有效时，**所有输出描述的
 * 都是图像坐标 (x-1,y-1) 的那个像素**，与 imgproc 系列的空间约定完全一致：
 *
 *     输出槽位 (x,y) 上的结果 = 图像 (x-1,y-1) 像素的颜色 + 形状特征
 *     （整幅图右下偏 1 像素，i_rgb 到 o_valid 固定 6 拍）
 *
 * 拍数账（都从窗口输出起算）：
 *     颜色路：det_color_feat 4 拍（纯逐像素流水）
 *     形状路：det_shape_feat  2 拍（幅度 1 + 方向 1）→ 顶层补 2 拍 = 4 拍
 *     o_rgb ：p11 延迟 4 拍
 *   三条支路都由窗口的 valid/frame_start 门控，延迟级数补齐后逐拍相同
 *   （TB 会逐拍比较两路 valid），i_frame_start 同拍挪 6 拍。
 *
 * ---------------------------------------------------------------------------
 * 接口约定（与 imgproc_top / cvp_proc 输出一致）：
 *   1 像素/拍 RGB888，i_valid 高时有效，允许组间气泡；
 *   i_frame_start 与一帧第 2 个输入像素同拍；
 *   输入 W x H 个像素输出 W x H 组特征（窗口复制边界，无帧时序变化）。
 *
 * 用法：典型接法是"并接抽头"——主像素通路（cvp_proc → imgproc_top →
 *   cvp_frame_buffer）不动，把 imgproc_top 的输入（或输出）同时接到本模块
 *   i_valid/i_rgb/i_frame_start，特征输出口留给后续阈值判定/连通域模块。
 *   本模块不改主通路任何时序，不接入时对现有工程零影响。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_feat_top #(
    /* 公共 */
    parameter IMG_W = 1280,                     // 图像宽（跟随工程 SC500CS 720P 规格）
    parameter IMG_H = 720,                      // 图像高

    /* 颜色分类阈值（det_color_feat） */
    parameter [7:0] V_MIN   = 8'd40,            // V 低于此值判背景
    parameter [7:0] S_MIN   = 8'd60,            // S 低于此值走白/背景支路
    parameter [7:0] WHITE_V = 8'd200,           // 低饱和且亮于此值 -> 白
    parameter [9:0] HUE_RY  = 10'd85,           //  30° 红|黄
    parameter [9:0] HUE_YG  = 10'd199,          //  70° 黄|绿
    parameter [9:0] HUE_GC  = 10'd455,          // 160° 绿|青
    parameter [9:0] HUE_CB  = 10'd569,          // 200° 青|蓝
    parameter [9:0] HUE_BM  = 10'd796,          // 280° 蓝|品红
    parameter [9:0] HUE_MR  = 10'd939,          // 330° 品红|红

    /* 形状特征阈值（det_shape_feat） */
    parameter [10:0] EDGE_TH = 11'd130          // 轮廓判决阈值
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_valid,
    input  wire [23:0] i_rgb,
    input  wire        i_frame_start,

    /* 特征输出：o_valid 高时全部有效，且描述同一个像素 (x-1,y-1) */
    output wire        o_valid,
    output wire        o_frame_start,
    output wire [23:0] o_rgb,          // 特征所在像素的原图颜色（对齐用）
    /* 颜色特征 */
    output wire [9:0]  o_hue,          // 0~1023 <-> 0°~360°
    output wire [7:0]  o_sat,          // 0~255
    output wire [7:0]  o_val,          // 0~255
    output wire [2:0]  o_cid,          // 0背景/1红/2黄/3绿/4青/5蓝/6品红/7白
    /* 形状特征 */
    output wire        o_edge,         // 1 = 轮廓像素
    output wire [10:0] o_mag,          // 梯度幅度（R/G/B 三通道最大）
    output wire [2:0]  o_dir           // 梯度方向八分区 0E/1SE/2S/3SW/4W/5NW/6N/7NE
);

    /* ================= 1. 共用 3x3 窗口（颜色/形状两路同一个） ================= */
    wire        w_win_v, w_win_fs;
    wire [23:0] w_p00, w_p01, w_p02, w_p10, w_p11, w_p12, w_p20, w_p21, w_p22;

    imgproc_win3x3 #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .DW    (24)
    ) u_win (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (i_valid),
        .i_data        (i_rgb),
        .i_frame_start (i_frame_start),
        .o_valid       (w_win_v),
        .o_frame_start (w_win_fs),
        .o_p00 (w_p00), .o_p01 (w_p01), .o_p02 (w_p02),
        .o_p10 (w_p10), .o_p11 (w_p11), .o_p12 (w_p12),
        .o_p20 (w_p20), .o_p21 (w_p21), .o_p22 (w_p22)
    );

    /* ================= 2. 颜色路：吃窗口中心 p11（窗口后 4 拍） ================= */
    /* 颜色是逐像素运算，喂 p11 就让它描述"窗口中心 (x-1,y-1)"那个像素，
     * 和形状路的窗口中心天然是同一个像素，只差拍数（见下面第 4 节补齐）。 */
    wire        w_cv, w_cfs;
    wire [9:0]  w_hue;
    wire [7:0]  w_sat, w_val;
    wire [2:0]  w_cid;

    det_color_feat #(
        .V_MIN   (V_MIN),
        .S_MIN   (S_MIN),
        .WHITE_V (WHITE_V),
        .HUE_RY  (HUE_RY),
        .HUE_YG  (HUE_YG),
        .HUE_GC  (HUE_GC),
        .HUE_CB  (HUE_CB),
        .HUE_BM  (HUE_BM),
        .HUE_MR  (HUE_MR)
    ) u_color (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_win_v),
        .i_rgb         (w_p11),
        .i_frame_start (w_win_fs),
        .o_valid       (w_cv),
        .o_frame_start (w_cfs),
        .o_hue         (w_hue),
        .o_sat         (w_sat),
        .o_val         (w_val),
        .o_cid         (w_cid)
    );

    /* ================= 3. 形状路：吃 9 个窗口抽头（窗口后 2 拍） ================= */
    wire        w_sv, w_sfs;
    wire        w_edge;
    wire [10:0] w_mag;
    wire [2:0]  w_dir;

    det_shape_feat #(
        .EDGE_TH (EDGE_TH)
    ) u_shape (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_win_v),
        .i_frame_start (w_win_fs),
        .i_p00 (w_p00), .i_p01 (w_p01), .i_p02 (w_p02),
        .i_p10 (w_p10), .i_p11 (w_p11), .i_p12 (w_p12),
        .i_p20 (w_p20), .i_p21 (w_p21), .i_p22 (w_p22),
        .o_valid       (w_sv),
        .o_frame_start (w_sfs),
        .o_edge        (w_edge),
        .o_mag         (w_mag),
        .o_dir         (w_dir)
    );

    /* ================= 4. 形状路补 2 拍（2 -> 4，与颜色路同拍） ================= */
    reg        r_shv1, r_shfs1, r_shedge1, r_shv2, r_shfs2, r_shedge2;
    reg [10:0] r_shmag1, r_shmag2;
    reg [2:0]  r_shdir1, r_shdir2;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_shv1 <= 1'b0;  r_shfs1 <= 1'b0;  r_shedge1 <= 1'b0;
            r_shmag1 <= 11'd0;  r_shdir1 <= 3'd0;
            r_shv2 <= 1'b0;  r_shfs2 <= 1'b0;  r_shedge2 <= 1'b0;
            r_shmag2 <= 11'd0;  r_shdir2 <= 3'd0;
        end else begin
            r_shv1 <= w_sv;
            if (w_sv) begin
                r_shfs1   <= w_sfs;
                r_shedge1 <= w_edge;
                r_shmag1  <= w_mag;
                r_shdir1  <= w_dir;
            end

            r_shv2 <= r_shv1;
            if (r_shv1) begin
                r_shfs2   <= r_shfs1;
                r_shedge2 <= r_shedge1;
                r_shmag2  <= r_shmag1;
                r_shdir2  <= r_shdir1;
            end
        end
    end

    /* ================= 5. o_rgb：p11 延迟 4 拍（与颜色路同拍） ================= */
    reg        r_rv1, r_rfs1, r_rv2, r_rfs2, r_rv3, r_rfs3, r_rv4, r_rfs4;
    reg [23:0] r_rp1, r_rp2, r_rp3, r_rp4;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rv1 <= 1'b0;  r_rfs1 <= 1'b0;  r_rp1 <= 24'd0;
            r_rv2 <= 1'b0;  r_rfs2 <= 1'b0;  r_rp2 <= 24'd0;
            r_rv3 <= 1'b0;  r_rfs3 <= 1'b0;  r_rp3 <= 24'd0;
            r_rv4 <= 1'b0;  r_rfs4 <= 1'b0;  r_rp4 <= 24'd0;
        end else begin
            r_rv1 <= w_win_v;
            if (w_win_v) begin
                r_rfs1 <= w_win_fs;
                r_rp1  <= w_p11;
            end

            r_rv2 <= r_rv1;
            if (r_rv1) begin
                r_rfs2 <= r_rfs1;
                r_rp2  <= r_rp1;
            end

            r_rv3 <= r_rv2;
            if (r_rv2) begin
                r_rfs3 <= r_rfs2;
                r_rp3  <= r_rp2;
            end

            r_rv4 <= r_rv3;
            if (r_rv3) begin
                r_rfs4 <= r_rfs3;
                r_rp4  <= r_rp3;
            end
        end
    end

    /* ================= 6. 输出（三路 4 拍对齐，总线取颜色路） ================= */
    assign o_valid        = w_cv;
    assign o_frame_start  = w_cfs;
    assign o_rgb          = r_rp4;
    assign o_hue          = w_hue;
    assign o_sat          = w_sat;
    assign o_val          = w_val;
    assign o_cid          = w_cid;
    assign o_edge         = r_shedge2;
    assign o_mag          = r_shmag2;
    assign o_dir          = r_shdir2;

    /* 形状路补齐后的 valid/frame_start 仅供断言/调试（TB 逐拍比 o_valid），
     * 不外接成端口，避免接口膨胀。 */
    wire unused_shape_valid = r_shv2;
    wire unused_shape_fs    = r_shfs2;
    wire unused_rgb_valid   = r_rv4;
    wire unused_rgb_fs      = r_rfs4;

endmodule
