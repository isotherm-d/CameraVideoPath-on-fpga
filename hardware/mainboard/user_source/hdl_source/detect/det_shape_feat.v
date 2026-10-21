/*
 * ============================================================================
 * det_shape_feat —— 形状特征提取（扩展要求 2：目标检测与识别）
 *
 * 在赛题推荐链路
 *     MIPI 输入 → ISP 预处理 → 【颜色/形状特征提取】→ 阈值判定
 *     → 连通域/坐标计算 → OSD 结果叠加 → HDMI 显示
 * 中，本模块负责"形状特征提取"这一级，对 3x3 窗口逐像素输出：
 *
 *     o_edge —— 该像素是否为形状轮廓（梯度幅度 >= EDGE_TH）
 *     o_mag  —— 梯度幅度 |Gx|+|Gy|（0~2040，阈值判定级可拿去做双阈值/滞后）
 *     o_dir  —— 梯度方向 8 量化（45° 一档，做方向直方图区分矩形/圆/三角）
 *
 * 连通域、外接框、坐标计算都在下游，本模块不做。
 *
 * ---------------------------------------------------------------------------
 * 【输入是 3x3 窗口，不是像素流】
 * 接法和 imgproc_sobel 一样：窗口由 imgproc_win3x3 生成（det_feat_top 里
 * 只放一个窗口，颜色/形状两路共用）。窗口中心是 i_p11 = 源图坐标
 * (x-1,y-1)，所以检出的轮廓整体右下偏 1 像素 —— 这是流式 3x3 的固有
 * 延迟，与 imgproc 系列的空间约定一致（见 imgproc_win3x3.v 文件头）。
 *
 * 【为什么在 R/G/B 三个平面上分别算 Sobel】
 * 亮度 Y=(R+2G+B)/4 是线性的：纯红块 (Y=64) 放在灰底 (Y=64) 上，亮度平面
 * 完全看不到边缘 —— 而赛题的目标恰恰主要是"中性背景上的彩色几何形状"。
 * 所以对 R/G/B 三通道各算一组 3x3 Sobel，取幅度最大的通道作为该像素的
 * 形状特征：mag = max(mag_R, mag_G, mag_B)，方向取幅度最大通道的 (Gx,Gy)。
 * 灰度边缘（R≈G≈B）三平面梯度相同，退化为普通单平面 Sobel；
 * 等亮度彩色边缘由对应通道检出 —— 两种情况都覆盖。
 * （数学上 max 通道幅度 >= 亮度平面幅度，亮度平面是冗余的，不用算。）
 *
 * Sobel 核与 imgproc_sobel 完全一致（"和之差"写法）：
 *     Gx = (p02 + 2*p12 + p22) - (p00 + 2*p10 + p20)
 *     Gy = (p20 + 2*p21 + p22) - (p00 + 2*p01 + p02)
 *     mag = |Gx| + |Gy|（饱和 2040），>= EDGE_TH 判轮廓（默认 130，与例程
 *     edge_detect_96 / imgproc_sobel 的 TH_LOW 同值；双阈值滞后等抗噪判决
 *     是下游"阈值判定"级的事，这里只出原始特征，阈值判定想怎么用都行）。
 *
 * ---------------------------------------------------------------------------
 * 梯度方向 o_dir 的编码（图像 y 轴向下；45° 一档，共 8 档）：
 *
 *        6:N(270°)  7:NE(315°)      方向 = 梯度指向（指向更亮一侧），
 *        5:NW(225°) 0:E(0°)         与边缘切线垂直。
 *        4:W(180°)  1:SE(45°)
 *        3:SW(135°) 2:S(90°)
 *
 *   八分区判决不用除法/三角函数，只用两个常数乘法比较：
 *     |Gy|*256 <  |Gx|*106  -> 水平左右档（tan22.5° ≈ 106/256）
 *     |Gy|*256 >  |Gx|*617  -> 上下档   （tan67.5° ≈ 617/256）
 *     其间 -> 斜对角档
 *   再按 Gx/Gy 符号选出 8 个方向之一。平坦像素（mag=0）dir 无意义，
 *   固定输出 SE(1)，用 o_edge 区分即可。
 *
 * 时序：窗口有效 -> 本模块输出固定 2 拍（幅度/边缘 1 拍 + 方向 1 拍）；
 *       det_feat_top 里再把形状路延迟 2 拍，与颜色路（窗口后 4 拍）
 *       对齐成总共 6 拍，两组特征才落到同一个输出拍上。
 *
 * 资源：三通道 Sobel 加法 + 2 个常数乘法（106/617，可移位加实现）+
 *       比较器；无行缓存（行缓存在共用的 imgproc_win3x3 里）、无 DSP 必要。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_shape_feat #(
    parameter [10:0] EDGE_TH = 11'd130  // 轮廓判决阈值（与 imgproc_sobel TH_LOW 同默认值）
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_valid,         // 窗口有效（imgproc_win3x3 的 o_valid）
    input  wire        i_frame_start,   // 与窗口输出同拍的 frame_start
    input  wire [23:0] i_p00, i_p01, i_p02,
    input  wire [23:0] i_p10, i_p11, i_p12,
    input  wire [23:0] i_p20, i_p21, i_p22,

    output reg         o_valid,
    output reg         o_frame_start,
    output reg         o_edge,          // 1 = 形状轮廓像素
    output reg  [10:0] o_mag,           // 梯度幅度（三通道最大）
    output reg  [2:0]  o_dir            // 梯度方向八分区，见文件头编码
);

    /* ================= 1. 单通道 Gx / Gy（Sobel "和之差"写法） ================= */
    function signed [11:0] gx_of;
        input [7:0] a00, a01, a02, a10, a12, a20, a21, a22;
        reg   [10:0] sr, sl;
        begin
            sr = a02 + a12*2 + a22;
            sl = a00 + a10*2 + a20;
            gx_of = $signed({1'b0, sr}) - $signed({1'b0, sl});
        end
    endfunction

    function signed [11:0] gy_of;
        input [7:0] a00, a01, a02, a10, a12, a20, a21, a22;
        reg   [10:0] sd, su;
        begin
            sd = a20 + a21*2 + a22;
            su = a00 + a01*2 + a02;
            gy_of = $signed({1'b0, sd}) - $signed({1'b0, su});
        end
    endfunction

    /* R 平面 */
    wire signed [11:0] w_gx_r = gx_of(i_p00[23:16], i_p01[23:16], i_p02[23:16],
                                      i_p10[23:16], i_p12[23:16],
                                      i_p20[23:16], i_p21[23:16], i_p22[23:16]);
    wire signed [11:0] w_gy_r = gy_of(i_p00[23:16], i_p01[23:16], i_p02[23:16],
                                      i_p10[23:16], i_p12[23:16],
                                      i_p20[23:16], i_p21[23:16], i_p22[23:16]);
    /* G 平面 */
    wire signed [11:0] w_gx_g = gx_of(i_p00[15:8], i_p01[15:8], i_p02[15:8],
                                      i_p10[15:8], i_p12[15:8],
                                      i_p20[15:8], i_p21[15:8], i_p22[15:8]);
    wire signed [11:0] w_gy_g = gy_of(i_p00[15:8], i_p01[15:8], i_p02[15:8],
                                      i_p10[15:8], i_p12[15:8],
                                      i_p20[15:8], i_p21[15:8], i_p22[15:8]);
    /* B 平面 */
    wire signed [11:0] w_gx_b = gx_of(i_p00[7:0], i_p01[7:0], i_p02[7:0],
                                      i_p10[7:0], i_p12[7:0],
                                      i_p20[7:0], i_p21[7:0], i_p22[7:0]);
    wire signed [11:0] w_gy_b = gy_of(i_p00[7:0], i_p01[7:0], i_p02[7:0],
                                      i_p10[7:0], i_p12[7:0],
                                      i_p20[7:0], i_p21[7:0], i_p22[7:0]);

    /* ================= 2. 单通道幅度 |Gx|+|Gy|（饱和 2040，同 imgproc_sobel） ================= */
    wire [11:0] w_ax_r = w_gx_r[11] ? (~w_gx_r + 12'd1) : w_gx_r;
    wire [11:0] w_ay_r = w_gy_r[11] ? (~w_gy_r + 12'd1) : w_gy_r;
    wire [11:0] w_ax_g = w_gx_g[11] ? (~w_gx_g + 12'd1) : w_gx_g;
    wire [11:0] w_ay_g = w_gy_g[11] ? (~w_gy_g + 12'd1) : w_gy_g;
    wire [11:0] w_ax_b = w_gx_b[11] ? (~w_gx_b + 12'd1) : w_gx_b;
    wire [11:0] w_ay_b = w_gy_b[11] ? (~w_gy_b + 12'd1) : w_gy_b;

    wire [11:0] w_mf_r = w_ax_r + w_ay_r;
    wire [11:0] w_mf_g = w_ax_g + w_ay_g;
    wire [11:0] w_mf_b = w_ax_b + w_ay_b;
    wire [10:0] w_mag_r = (w_mf_r > 12'd2040) ? 11'd2040 : w_mf_r[10:0];
    wire [10:0] w_mag_g = (w_mf_g > 12'd2040) ? 11'd2040 : w_mf_g[10:0];
    wire [10:0] w_mag_b = (w_mf_b > 12'd2040) ? 11'd2040 : w_mf_b[10:0];

    /* 三通道取最大（严格大于，并列时按 R > G > B 优先，参考模型同序） */
    wire        w_selg  = (w_mag_g > w_mag_r);
    wire [10:0] w_mag_rg = w_selg ? w_mag_g : w_mag_r;
    wire        w_selb  = (w_mag_b > w_mag_rg);
    wire [10:0] w_mag   = w_selb ? w_mag_b : w_mag_rg;
    wire [1:0]  w_sel   = w_selb ? 2'd2 : (w_selg ? 2'd1 : 2'd0);

    /* ================= 3. S3：幅度/边缘/选择打 1 拍，Gx/Gy 原值保留 ================= */
    reg        r_v3, r_fs3;
    reg [1:0]  r_sel;
    reg [10:0] r_mag;
    reg        r_edge;
    reg signed [11:0] r_gx_r, r_gy_r, r_gx_g, r_gy_g, r_gx_b, r_gy_b;

    /* ================= 4. S4：按选中通道算 8 方向（打 1 拍输出） ================= */
    wire signed [11:0] w_gx_sel = (r_sel == 2'd2) ? r_gx_b :
                                  (r_sel == 2'd1) ? r_gx_g : r_gx_r;
    wire signed [11:0] w_gy_sel = (r_sel == 2'd2) ? r_gy_b :
                                  (r_sel == 2'd1) ? r_gy_g : r_gy_r;

    wire [11:0] w_ax = w_gx_sel[11] ? (~w_gx_sel + 12'd1) : w_gx_sel;
    wire [11:0] w_ay = w_gy_sel[11] ? (~w_gy_sel + 12'd1) : w_gy_sel;

    /* |Gy|*256 与 |Gx|*106 / |Gx|*617 比（tan22.5°/tan67.5°），无除法 */
    wire [19:0] w_y256 = w_ay * 12'd256;
    wire [19:0] w_x106 = w_ax * 11'd106;
    wire [19:0] w_x617 = w_ax * 11'd617;

    wire w_near_h = (w_y256 < w_x106);
    wire w_near_v = (w_y256 > w_x617);

    wire [2:0] w_dir = w_near_h ? (w_gx_sel[11] ? 3'd4 : 3'd0)      // W : E
                    : w_near_v ? (w_gy_sel[11] ? 3'd6 : 3'd2)        // N : S
                    : (w_gx_sel[11] ? (w_gy_sel[11] ? 3'd5 : 3'd3)   // NW : SW
                                    : (w_gy_sel[11] ? 3'd7 : 3'd1)); // NE : SE

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            /* S3 */
            r_v3 <= 1'b0;  r_fs3 <= 1'b0;
            r_sel <= 2'd0;  r_mag <= 11'd0;  r_edge <= 1'b0;
            r_gx_r <= 12'd0;  r_gy_r <= 12'd0;
            r_gx_g <= 12'd0;  r_gy_g <= 12'd0;
            r_gx_b <= 12'd0;  r_gy_b <= 12'd0;
            /* S4 */
            o_valid <= 1'b0;  o_frame_start <= 1'b0;
            o_edge <= 1'b0;  o_mag <= 11'd0;  o_dir <= 3'd0;
        end else begin
            /* ---------- S3 ---------- */
            r_v3 <= i_valid;
            if (i_valid) begin
                r_fs3  <= i_frame_start;
                r_sel  <= w_sel;
                r_mag  <= w_mag;
                r_edge <= (w_mag >= EDGE_TH);
                r_gx_r <= w_gx_r;  r_gy_r <= w_gy_r;
                r_gx_g <= w_gx_g;  r_gy_g <= w_gy_g;
                r_gx_b <= w_gx_b;  r_gy_b <= w_gy_b;
            end

            /* ---------- S4 ---------- */
            o_valid <= r_v3;
            if (r_v3) begin
                o_frame_start <= r_fs3;
                o_edge <= r_edge;
                o_mag  <= r_mag;
                o_dir  <= w_dir;
            end
        end
    end

endmodule
