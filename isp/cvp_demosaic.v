/*
 * ============================================================================
 * cvp_demosaic —— 3x3 双线性彩色重建（BGGR）
 *
 * 替代原来 cvp_proc 里那段“2 行近似”重建。原实现结构上就是坏的：
 * 用探针 TB（每个像素喂唯一编号，反推各通道取了哪个源像素）扫遍所有对齐偏移，
 * 输出跟任何合理的 2 行模型都对不上（最好仍 22/32 不一致，还出现 R=G 这种畸形组合），
 * 彩色块自检也证实饱和色会出现相邻色平面互换。所以这里按教科书做法重写。
 *
 * 做法：
 *   1. 用 imgproc_win3x3（已在独立 TB 里逐像素验证过、且与位宽无关）把 10bit RAW 流
 *      变成 3x3 邻域，中心是 p11；
 *        p00 p01 p02      (左上, 上,   右上)
 *        p10 p11 p12      (左,   中心, 右)
 *        p20 p21 p22      (左下, 下,   右下)
 *   2. 按 BGGR 相位（偶行 B G B G / 奇行 G R G R）对缺的通道做双线性插值：
 *        B 中心：B=自己, G=上下左右 4 邻域均值, R=4 对角均值
 *        R 中心：R=自己, G=上下左右 4 邻域均值, B=4 对角均值
 *        G 中心(偶行)：G=自己, R=上下均值, B=左右均值
 *        G 中心(奇行)：G=自己, B=上下均值, R=左右均值
 *   3. 10bit → 8bit 取高 8 位（和工具里“8bit 左移 2 位”的约定一致）。
 *
 * 时序：窗口 2 拍 + 输出寄存器 1 拍 = 固定 3 拍；valid / frame_start 同步延迟。
 * 边界：由 imgproc_win3x3 做复制边界，所以整幅 WxH 都出像素。
 * ============================================================================
 */
`timescale 1ns/1ps

module cvp_demosaic #(
    parameter IMG_W = 1024,
    parameter IMG_H = 600
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_valid,
    input  wire [9:0]  i_raw,
    input  wire        i_frame_start,

    output reg         o_valid,
    output reg  [23:0] o_rgb,
    output reg         o_frame_start
);

    /* ---------------- 1. 3x3 RAW 窗口 ---------------- */
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

    /* ---------------- 2. 中心像素的行列相位 ----------------
     * 窗口输出本身就是栅格序（中心 (x-1,y-1) 顺序排列），所以按 o_valid 计数即可
     * 得到中心的行列号；BGGR 相位：偶行偶列=B、偶行奇列=G、奇行偶列=G、奇行奇列=R。 */
    reg [10:0] r_col, r_row;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_col <= 11'd0;
            r_row <= 11'd0;
        end else if (w_win_valid) begin
            if (r_col == IMG_W-1) begin
                r_col <= 11'd0;
                r_row <= (r_row == IMG_H-1) ? 11'd0 : (r_row + 11'd1);
            end else begin
                r_col <= r_col + 11'd1;
            end
        end
    end

    /* ⚠ 行相位：实测（色块自检 + 四个相位变体逐个试）发现数据到达本模块时，
     * 第一行对应的是 BGGR 的“奇行”（G R G R），也就是比 BGGR 的假设差一整行。
     * 所以这里用 r_row[0] 而不是 ~r_row[0] —— 改这一根线就能整体翻转行相位；
     * 如果以后换摄像头/改流水线导致颜色又不对，先用 tools/video_joint_sim.py --patches 复核。 */
    wire w_row_even = r_row[0];
    wire w_col_even = ~r_col[0];

    /* ---------------- 3. 双线性插值（先用 12bit 免溢出，最后取高 8 位） ---------------- */
    wire [11:0] w_sum4 = p01 + p10 + p12 + p21;      // 上下左右（4 邻域）
    wire [11:0] w_sumd = p00 + p02 + p20 + p22;      // 4 个对角
    wire [11:0] w_sumv = p01 + p21;                  // 上、下
    wire [11:0] w_sumh = p10 + p12;                  // 左、右

    reg  [11:0] y_r, y_g, y_b;
    always @(*) begin
        case ({w_row_even, w_col_even})
            2'b10: begin                             // 偶行偶列：B 像素
                y_b = {2'b0, p11};
                y_g = (w_sum4 + 12'd2) >> 2;         // 4 邻域均值（四舍五入）
                y_r = (w_sumd + 12'd2) >> 2;         // 4 对角均值
            end
            2'b11: begin                             // 偶行奇列：G 像素（上下是 R、左右是 B）
                y_g = {2'b0, p11};
                y_r = (w_sumv + 12'd1) >> 1;
                y_b = (w_sumh + 12'd1) >> 1;
            end
            2'b00: begin                             // 奇行偶列：G 像素（上下是 B、左右是 R）
                y_g = {2'b0, p11};
                y_b = (w_sumv + 12'd1) >> 1;
                y_r = (w_sumh + 12'd1) >> 1;
            end
            default: begin                           // 奇行奇列：R 像素
                y_r = {2'b0, p11};
                y_g = (w_sum4 + 12'd2) >> 2;
                y_b = (w_sumd + 12'd2) >> 2;
            end
        endcase
    end

    /* ---------------- 4. 输出寄存器（10bit -> 8bit） ---------------- */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_valid       <= 1'b0;
            o_rgb         <= 24'd0;
            o_frame_start <= 1'b0;
        end else begin
            o_valid <= w_win_valid;
            if (w_win_valid) begin
                o_rgb         <= { y_r[9:2], y_g[9:2], y_b[9:2] };
                o_frame_start <= w_win_fs;
            end
        end
    end

endmodule