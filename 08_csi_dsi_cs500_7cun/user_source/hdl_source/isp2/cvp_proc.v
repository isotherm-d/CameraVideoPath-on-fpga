/*
 * ============================================================================
 * cvp_proc —— RAW10 解包成像素流 + 3x3 双线性彩色重建（自研）
 *
 * 输入：cvp_rx_pipeline 的 4 像素/拍 RAW10 组（40bit，低 10bit=像素0）
 * 输出：1 像素/拍 RGB888（100MHz），供后续 AWB / 算法 / 帧缓存使用。
 *
 * 本模块分三步：
 *   1) 齿轮箱（gearbox）：把 4 像素/拍的 40bit 组展开成 1 像素/拍的 10bit 流。
 *   2) 坏点检测/矫正：交给 cvp_dpc（RAW 域 3x3 同色判据，命中才用同色邻居
 *      中位数替换，其余直通）。必须在彩色重建之前修 —— 坏点经过 demosaic
 *      会扩散成 5 像素的十字彩色斑。固定 4 拍延迟（判据/矫正两级流水）。
 *   3) 彩色重建：交给 cvp_demosaic（3x3 双线性，BGGR），固定 3 拍延迟。
 *      —— 原来那段“2 行近似”重建结构上就是坏的（探针 TB 扫遍所有对齐都对不上、
 *         色块自检饱和色会互换色平面），已整体替换。
 *
 * 算法模式 i_mode（保留的像素级算法；在 cvp_top 里现在固定送 0，
 * 因为 3x3 的算法（高斯/中值/真 Sobel）已经搬到 imgproc_top）：
 *   0 = 原摄像头输出（彩色重建结果直通）
 *   1 = 灰度：Y = (R + 2G + B) >> 2
 *   2 = 二值化：Y >= 128 为白，否则为黑
 *   3 = 灰度（原“简化边缘”已由 imgproc 的真 Sobel 取代，这里保留为灰度）
 *   4 = 反色
 *   5 = 红蓝通道交换（伪彩）
 *   6 = 亮度增强（每个通道 +32，饱和到 255）
 *
 * Bayer 相位：BGGR，即
 *   row even: B G B G ...
 *   row odd : G R G R ...
 * ============================================================================
 */
module cvp_proc #(
    parameter IMG_W = 1024,
    parameter IMG_H = 600,
    parameter [10:0] EDGE_THRESH = 11'd60   // 保留参数（兼容旧例化；当前模式里未使用）
) (
    input  wire         i_clk,
    input  wire         i_rst_n,
    input  wire [2:0]   i_mode,

    input  wire         i_grp_valid,
    input  wire [39:0]  i_grp_data,
    input  wire         i_grp_frame_start,
    input  wire         i_grp_line_last,

    output reg          o_pix_valid,
    output reg  [23:0]  o_pix_rgb,
    output reg          o_pix_frame_start,
    output reg          o_pix_line_last,

    /* AE（自动曝光）：统计与控制律在本模块内，等效曝光/寄存器写接口引出到顶层。
     * o_eq_q8 仿真里喂给传感器曝光模型（cvp_top_sim 的 cvp_sensor_sim）成闭环；
     * o_req/o_exp/o_gain 上板接 cvp_cam_cfg 写 SC500CS 曝光寄存器。 */
    output wire [15:0]  o_ae_eq_q8,
    output wire         o_ae_update,
    output wire         o_ae_req,
    output wire [19:0]  o_ae_exp,
    output wire [15:0]  o_ae_gain,
    output wire         o_ae_locked,
    output wire [10:0]  o_ae_dbg              // v19e: {状态机[2:0], eq_q8 高 8 位}
);

    /* ================= 1. 齿轮箱：4 像素/拍 → 1 像素/拍 ================= */
    reg [9:0]  r_p0, r_p1, r_p2, r_p3;
    reg [2:0]  r_pix_cnt;      // 当前组里还剩几个像素没弹出
    reg [1:0]  r_pop_idx;      // 下一个弹出的像素序号
    reg        r_fs_lat, r_last_lat;
    wire [9:0] w_pix_sel = (r_pop_idx == 2'd0) ? r_p0 :
                           (r_pop_idx == 2'd1) ? r_p1 :
                           (r_pop_idx == 2'd2) ? r_p2 : r_p3;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_p0 <= 10'd0; r_p1 <= 10'd0; r_p2 <= 10'd0; r_p3 <= 10'd0;
            r_pix_cnt <= 3'd0;
            r_pop_idx <= 2'd0;
            r_fs_lat  <= 1'b0;
            r_last_lat<= 1'b0;
        end else begin
            if (i_grp_valid && r_pix_cnt == 3'd0) begin
                /* 取出一组 4 像素；本设计组速率远低于 100MHz，4 拍内必弹空 */
                r_p0      <= i_grp_data[9:0];
                r_p1      <= i_grp_data[19:10];
                r_p2      <= i_grp_data[29:20];
                r_p3      <= i_grp_data[39:30];
                r_pix_cnt <= 3'd4;
                r_pop_idx <= 2'd0;
                r_fs_lat  <= i_grp_frame_start;
                r_last_lat<= i_grp_line_last;
            end else if (r_pix_cnt != 3'd0) begin
                r_pix_cnt <= r_pix_cnt - 3'd1;
                r_pop_idx <= r_pop_idx + 2'd1;
            end
        end
    end

    wire w_pix_step = (r_pix_cnt != 3'd0);
    wire w_pix_fs   = w_pix_step && (r_pop_idx == 2'd0) && r_fs_lat;
    wire w_pix_last = w_pix_step && (r_pop_idx == 2'd3) && r_last_lat;

    /* ================= 2. 坏点检测/矫正：RAW 域 3x3 同色 DPC ================= */
    wire        w_dpc_valid, w_dpc_fs;
    wire [9:0]  w_dpc_raw;

    cvp_dpc #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H)
    ) u_dpc (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_pix_step),
        .i_raw         (w_pix_sel),
        .i_frame_start (w_pix_fs),
        .o_valid       (w_dpc_valid),
        .o_raw         (w_dpc_raw),
        .o_frame_start (w_dpc_fs)
    );

    wire [10:0] o_ae_dbg;
    /* ================= 2b. 自动曝光：RAW 域统计 + 帧尾控制律（并联只读，不占像素通路） ================= */
    cvp_ae #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H)
    ) u_ae (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_pix_step),
        .i_raw         (w_pix_sel),
        .i_frame_start (w_pix_fs),
        .o_eq_q8       (o_ae_eq_q8),
        .o_update      (o_ae_update),
        .o_req         (o_ae_req),
        .o_exp         (o_ae_exp),
        .o_gain        (o_ae_gain),
        .o_locked      (o_ae_locked),
        .o_dbg         (o_ae_dbg)
    );

    /* ================= 3. 彩色重建：3x3 双线性（BGGR） ================= */
    wire        w_dem_valid, w_dem_fs;
    wire [23:0] w_dem_rgb;

    cvp_demosaic #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H)
    ) u_demosaic (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_dpc_valid),
        .i_raw         (w_dpc_raw),
        .i_frame_start (w_dpc_fs),
        .o_valid       (w_dem_valid),
        .o_rgb         (w_dem_rgb),
        .o_frame_start (w_dem_fs)
    );

    /* ================= 4. 像素级算法模式（保留） ================= */
    wire [7:0] w_r = w_dem_rgb[23:16];
    wire [7:0] w_g = w_dem_rgb[15:8];
    wire [7:0] w_b = w_dem_rgb[7:0];

    wire [9:0] w_gray10 = ({2'b0, w_r} + {2'b0, w_g} * 2 + {2'b0, w_b}) >> 2;
    wire [7:0] w_gray8  = w_gray10[7:0];
    wire [7:0] w_r_add  = (w_r > 8'd223) ? 8'hFF : (w_r + 8'd32);
    wire [7:0] w_g_add  = (w_g > 8'd223) ? 8'hFF : (w_g + 8'd32);
    wire [7:0] w_b_add  = (w_b > 8'd223) ? 8'hFF : (w_b + 8'd32);

    reg [23:0] r_rgb;
    always @(*) begin
        case (i_mode)
            3'd0:    r_rgb = w_dem_rgb;
            3'd1:    r_rgb = {w_gray8, w_gray8, w_gray8};
            3'd2:    r_rgb = (w_gray8 >= 8'd128) ? 24'hFFFFFF : 24'h000000;
            3'd3:    r_rgb = {w_gray8, w_gray8, w_gray8};   // 原简化边缘已由 imgproc 真 Sobel 取代
            3'd4:    r_rgb = {~w_r, ~w_g, ~w_b};
            3'd5:    r_rgb = {w_b, w_g, w_r};
            default: r_rgb = {w_r_add, w_g_add, w_b_add};
        endcase
    end

    /* ================= 5. 输出寄存 ================= */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_pix_valid       <= 1'b0;
            o_pix_rgb         <= 24'd0;
            o_pix_frame_start <= 1'b0;
            o_pix_line_last   <= 1'b0;
        end else begin
            o_pix_valid       <= w_dem_valid;
            o_pix_frame_start <= w_dem_fs;
            /* 行结束标记当前没被下游使用，先跟着 valid 走（保留原端口） */
            o_pix_line_last   <= w_dem_valid && w_pix_last;
            if (w_dem_valid)
                o_pix_rgb <= r_rgb;
        end
    end

endmodule