/*
 * ============================================================================
 * cvp_dpc —— RAW 域坏点检测与矫正（DPC, Defective Pixel Correction）
 *
 * 位置：cvp_proc 里齿轮箱之后、cvp_demosaic 之前（1 像素/拍 RAW10 流）。
 * 放在 demosaic 之前的原因：坏点一旦经过彩色重建会扩散成 5 像素的十字彩色斑，
 * 到 RGB 域再修就是补救了；RAW 域一个坏点只是一个孤立的 10bit 值，处理代价最小。
 *
 * 算法（经典“同色邻域”判据）：
 *   Bayer 排列下，3x3 窗口内与中心同色的恰好是 4 个对角点 —— 这对任何 2x2
 *   相位的 CFA（BGGR/GRBG/...）都成立，所以本模块不需要知道传感器相位。
 *   坏点的本质是“与所有同色邻居同时、同向、不连续地偏离”，据此两级判据：
 *     亮点坏点:  c > max(d_i) + TH    且    c > avg(d_i) + TH2
 *     暗点坏点:  c + TH < min(d_i)    且    c + TH2 < avg(d_i)
 *   只看 max/min 单阈值会把噪声尖峰误判成坏点（尤其高增益时），加上与均值的
 *   偏离量能滤掉大部分噪声；“四个邻居全部同向偏离”本身也抗纹理误检 —— 细线、
 *   边缘上邻居一亮一暗、方向不一致，不会触发。
 *   矫正：命中时输出 4 个同色邻居的中位数，未命中原样直通 —— 只动被判定的
 *   像素。这正是与 imgproc_median 那种全局中值滤波的本质区别（全局滤波会把
 *   整幅图的细节都过一遍，显微图像会伤分辨率）。
 *
 * 阈值：TH / TH2 为参数。固定阈值对高增益噪声不友好，后续可仿照 cvp_awb
 *   “上一帧统计调当前帧”的做法按帧调阈值；当前相机曝光固定，先用固定值。
 *
 * 边界（两处都选择“不矫正”，宁漏勿错）：
 *   1. imgproc_win3x3 复制边界：第 0/1 行、列的邻居被复制填充；窗口里出现与
 *      中心等值的邻居时，max>=c、min<=c，两个方向的判据自然失效，不会误矫。
 *   2. 每行第 1 个输出槽位：中心落在第 0 列，其“水平邻居”是上一行行尾回绕过
 *      来的像素，语义不可靠 —— 用列计数识别并直接旁路。
 *
 * 已知局限（接受）：宽度 1 像素的水平/垂直细线，其沿线的同色延续像素不在
 *   3x3 对角集合里（同行列是异色像素），判据看不到，会被当作坏点矫正掉。
 *   显微目标（细胞）远大于 1px，实际影响可忽略；若以后真出现 1px 细节，
 *   升级方案是 5x5 窗口取 8 个同色邻居（4 行缓存）。
 *
 * 时序：窗口 2 拍（imgproc_win3x3，与 cvp_demosaic 同款复用）+ 判据寄存 1 拍
 *   + 判定/矫正组合 + 输出寄存器 1 拍 = i_valid -> o_valid 固定 4 拍。
 *   最初判据/矫正收在一拍里，综合后 100MHz 写侧 SWNS 打到 -1.543ns（sort4 网络 +
 *   求和树 + 阈值加法 + 比较全串在一拍），已拆两级流水：第 1 拍寄存 sort4 输出与
 *   4 邻居均值，第 2 拍做阈值加法/比较/矫正选择。
 * ============================================================================
 */
`timescale 1ns/1ps

module cvp_dpc #(
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
