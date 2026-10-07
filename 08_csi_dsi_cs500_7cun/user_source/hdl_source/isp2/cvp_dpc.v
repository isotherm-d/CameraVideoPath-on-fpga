/*
 * RAW-domain DPC and equal-latency diagnostic bypass.
 *
 * IMPORTANT: the legacy 3x3 diagonal detector below mixes Bayer colours:
 * red centres have blue diagonals, and blue centres have red diagonals.
 * It can replace legitimate saturated colour with another colour. v25 therefore
 * instantiates BYPASS=1 in cvp_proc; tb_dpc_color reproduces this failure and
 * checks that the original RAW pixel is preserved with the bypass.
 *
 * Keep four-cycle timing and original RAW coordinates in the bypass.
 * A future enabled detector needs phase-aware, genuinely same-colour neighbours
 * (for example a 5x5 RAW window). BYPASS=0 is retained for regression comparison.
 */
`timescale 1ns/1ps

// Bypass preserves the original RAW coordinates, in addition to four-cycle
// timing. Passing the legacy window centre would shift the Bayer lattice.
module cvp_dpc #(
    parameter IMG_W=1024, IMG_H=600,
    parameter [9:0] TH=10'd64, TH2=10'd32,
    parameter BYPASS=0
) (
    input i_clk, i_rst_n, i_valid,
    input [9:0] i_raw, input i_frame_start,
    output o_valid, output [9:0] o_raw, output o_frame_start
);
    generate if (BYPASS) begin: raw_delay
        reg [3:0] v, fs;
        reg [9:0] d0,d1,d2,d3;
        always @(posedge i_clk or negedge i_rst_n) begin
            if (!i_rst_n) begin
                v<=0; fs<=0; d0<=0; d1<=0; d2<=0; d3<=0;
            end else begin
                v <= {v[2:0],i_valid};
                fs <= {fs[2:0],i_valid && i_frame_start};
                d0<=i_raw; d1<=d0; d2<=d1; d3<=d2;
            end
        end
        assign o_valid=v[3]; assign o_raw=d3; assign o_frame_start=fs[3];
    end else begin: legacy_comparison
        cvp_dpc_legacy #(.IMG_W(IMG_W),.IMG_H(IMG_H),.TH(TH),.TH2(TH2),.BYPASS(0)) detector (
            .i_clk(i_clk),.i_rst_n(i_rst_n),.i_valid(i_valid),.i_raw(i_raw),
            .i_frame_start(i_frame_start),.o_valid(o_valid),.o_raw(o_raw),.o_frame_start(o_frame_start)
        );
    end endgenerate
endmodule

module cvp_dpc_legacy #(
    parameter IMG_W  = 1024,         // 图像宽（行缓存深度）
    parameter IMG_H  = 600,
    parameter [9:0]  TH  = 10'd64,   // 与最亮/最暗同色邻居的最小偏离
    parameter [9:0]  TH2 = 10'd32,   // 与 4 邻居均值的额外偏离（滤噪声）
    parameter        BYPASS = 0      // 1 = 纯直通（对比用）
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    /* 1 像素/拍 RAW10 流（与 cvp_demosaic 输入约定一致） */
    input  wire        i_valid,
    input  wire [9:0]  i_raw,
    input  wire        i_frame_start,

    output reg         o_valid,
    output reg  [9:0]  o_raw,
    output reg         o_frame_start
);

    /* ---------------- 1. 3x3 RAW 窗口（复用 imgproc_win3x3） ---------------- */
    wire        w_win_valid, w_win_fs;
    wire [9:0]  p00, p01, p02, p10, p11, p12, p20, p21, p22;

    imgproc_win3x3 #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .DW    (10)
    ) u_win (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (i_valid),
        .i_data        (i_raw),
        .i_frame_start (i_frame_start),
        .o_valid       (w_win_valid),
        .o_frame_start (w_win_fs),
        .o_p00 (p00), .o_p01 (p01), .o_p02 (p02),
        .o_p10 (p10), .o_p11 (p11), .o_p12 (p12),
        .o_p20 (p20), .o_p21 (p21), .o_p22 (p22)
    );

    /* ---------------- 2. 4 个对角点 = 同色邻居 ---------------- */
    wire [9:0] d1 = p00;
    wire [9:0] d2 = p02;
    wire [9:0] d3 = p20;
    wire [9:0] d4 = p22;

    /* ---------------- 3. sort4 部分网络：max/min 判据 + 中位数共用 ---------------- */
    function [9:0] max2;
        input [9:0] a, b;
        max2 = (a > b) ? a : b;
    endfunction
    function [9:0] min2;
        input [9:0] a, b;
        min2 = (a < b) ? a : b;
    endfunction

    wire [9:0] w_ha = max2(d1, d2);
    wire [9:0] w_la = min2(d1, d2);
    wire [9:0] w_hb = max2(d3, d4);
    wire [9:0] w_lb = min2(d3, d4);
    wire [9:0] w_hi = max2(w_ha, w_hb);     // 4 邻居最大
    wire [9:0] w_lo = min2(w_la, w_lb);     // 4 邻居最小
    wire [9:0] w_mh = max2(w_la, w_lb);     // 中间两值（大）
    wire [9:0] w_ml = min2(w_ha, w_hb);     // 中间两值（小）

    /* ---------------- 4. 两级判据（全部抬到 12bit 无符号，避免加减溢出） ---------------- */
    wire [11:0] w_sum4  = {2'b0, d1} + {2'b0, d2} + {2'b0, d3} + {2'b0, d4};
    wire [11:0] w_avg   = w_sum4 >> 2;

    /* ---------------- 4b. 第 1 级流水：寄存 sort4 输出 / 均值 / 中心值 ----------------
     * 原来判据+矫正收在一拍（sort4 网络 + 求和树 + 阈值加法 + 比较全串行），
     * 100MHz 写侧 SWNS -1.543ns；这里把排序与均值先打一拍，第 2 拍只剩
     * 阈值加法 + 比较 + 选择，两级各自 ~3 层逻辑。延迟 3 -> 4 拍。 */
    reg        r_s1_valid, r_s1_fs, r_seam1;
    reg [9:0]  r_hi, r_lo, r_mh, r_ml;
    reg [11:0] r_avg;
    reg [9:0]  r_c;

    /* ---------------- 5. 行首槽位旁路：中心落在第 0 列，邻居跨行回绕 ----------------
     * 输出槽位按栅格序排列（中心 = (列-1, 行-1)），所以每行第 1 个输出槽位
     * 的中心在第 0 列 —— 该槽位的“水平邻居”是上一行行尾的像素，判据不可靠。 */
    reg [10:0] r_col;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            r_col <= 11'd0;
        else if (w_win_valid)
            r_col <= (r_col == IMG_W-1) ? 11'd0 : r_col + 11'd1;
    end
    wire w_seam = (r_col == 11'd0);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_s1_valid <= 1'b0;
            r_s1_fs    <= 1'b0;
            r_seam1    <= 1'b0;
            r_hi <= 10'd0; r_lo <= 10'd0; r_mh <= 10'd0; r_ml <= 10'd0;
            r_avg <= 12'd0; r_c <= 10'd0;
        end else begin
            /* valid/frame_start 必须无条件跟随窗口有效（行间空洞拍为 0），
             * 否则下游 demosaic 会把空洞当像素吞掉，逐行错位 */
            r_s1_valid <= w_win_valid;
            r_s1_fs    <= w_win_fs;
            r_seam1    <= w_seam;
            if (w_win_valid) begin
                r_hi <= w_hi; r_lo <= w_lo; r_mh <= w_mh; r_ml <= w_ml;
                r_avg <= w_avg;
                r_c   <= p11;
            end
        end
    end

    /* ---------------- 6. 第 2 拍：阈值加法 + 两级判据 + 矫正选择 ---------------- */
    wire [11:0] w_hi_p  = {2'b0, r_hi} + {2'b0, TH};
    wire [11:0] w_avg_p = r_avg + {2'b0, TH2};
    wire [11:0] w_c_th  = {2'b0, r_c} + {2'b0, TH};
    wire [11:0] w_c_th2 = {2'b0, r_c} + {2'b0, TH2};

    wire w_bright = (r_c > w_hi_p) && (r_c > w_avg_p);
    wire w_dark   = (w_c_th < {2'b0, r_lo}) && (w_c_th2 < r_avg);

    /* 4 数中位 = 中间两值均值（+1 四舍五入；和最大 2046，11 位放得下） */
    wire [10:0] w_med_sum = {1'b0, r_ml} + {1'b0, r_mh} + 11'd1;
    wire [9:0]  w_med     = w_med_sum[10:1];

    wire [9:0] w_out = (BYPASS)          ? r_c :
                       (r_seam1)         ? r_c :
                       (w_bright|w_dark) ? w_med : r_c;

    /* ---------------- 7. 输出寄存（valid / frame_start 跟数据同步平移） ---------------- */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_valid       <= 1'b0;
            o_raw         <= 10'd0;
            o_frame_start <= 1'b0;
        end else begin
            o_valid       <= r_s1_valid;
            o_frame_start <= r_s1_fs;
            if (r_s1_valid)
                o_raw <= w_out;
        end
    end

endmodule
