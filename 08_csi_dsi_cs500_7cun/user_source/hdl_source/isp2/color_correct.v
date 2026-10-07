`timescale 1ns / 1ns
/*****************************************************************
 color_correct —— 颜色标定模块(v14)
 用途: 标定流程 = 拍标准白纸 -> PC 抓帧算三通道比例 -> 改这里的
 parameter -> 编译。参数:
   SWAP_RB  : 1 = R/B 通道交换(Bayer 相位错配一键修)
   GAIN_R/G/B: Q8 增益(256=1.0x, 320=1.25x, 511≈2.0x), 饱和到 255
 位置: demosaic 输出 -> 本模块 -> pack_4(100M 域, 1像素/拍, 1 级寄存)
*****************************************************************/
module color_correct #(
    parameter             SWAP_RB = 0,
    parameter [8:0]       GAIN_R  = 9'd256,
    parameter [8:0]       GAIN_G  = 9'd256,
    parameter [8:0]       GAIN_B  = 9'd256
)(
    input          I_clk,
    input          I_rst_n,
    input          I_valid,
    input  [23:0]  I_rgb,
    input          I_frame_start,

    /* 运行时覆盖(v20 命令接收): 非零时覆盖参数默认值 */
    input  [8:0]   I_gain_r_rt,
    input  [8:0]   I_gain_g_rt,
    input  [8:0]   I_gain_b_rt,
    input          I_swap_rt,

    output reg         O_valid,
    output reg  [23:0] O_rgb,
    output reg         O_frame_start
);
    // Either the board calibration or the runtime command can request a swap.
    wire       w_use_swap = I_swap_rt | SWAP_RB;
    wire [7:0] w_in_r = w_use_swap ? I_rgb[7:0]   : I_rgb[23:16];
    wire [7:0] w_in_g = I_rgb[15:8];
    wire [7:0] w_in_b = w_use_swap ? I_rgb[23:16] : I_rgb[7:0];
    wire [8:0] w_gr = (I_gain_r_rt != 9'd0) ? I_gain_r_rt : GAIN_R[8:0];
    wire [8:0] w_gg = (I_gain_g_rt != 9'd0) ? I_gain_g_rt : GAIN_G[8:0];
    wire [8:0] w_gb = (I_gain_b_rt != 9'd0) ? I_gain_b_rt : GAIN_B[8:0];

    // Q8 means divide by 256, not 512. Keep the overflow bit before saturation.
    wire [16:0] w_mul_r = w_in_r * w_gr;
    wire [16:0] w_mul_g = w_in_g * w_gg;
    wire [16:0] w_mul_b = w_in_b * w_gb;

    wire [17:0] w_round_r = {1'b0, w_mul_r} + 18'd128;
    wire [17:0] w_round_g = {1'b0, w_mul_g} + 18'd128;
    wire [17:0] w_round_b = {1'b0, w_mul_b} + 18'd128;
    wire [7:0] w_out_r = (|w_round_r[17:16]) ? 8'hFF : w_round_r[15:8];
    wire [7:0] w_out_g = (|w_round_g[17:16]) ? 8'hFF : w_round_g[15:8];
    wire [7:0] w_out_b = (|w_round_b[17:16]) ? 8'hFF : w_round_b[15:8];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid       <= 1'b0;
            O_rgb         <= 24'd0;
            O_frame_start <= 1'b0;
        end else begin
            O_valid       <= I_valid;
            O_rgb         <= {w_out_r, w_out_g, w_out_b};
            O_frame_start <= I_frame_start;
        end
    end
endmodule
