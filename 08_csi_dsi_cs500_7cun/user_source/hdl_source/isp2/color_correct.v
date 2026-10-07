`timescale 1ns / 1ns
/*****************************************************************
 color_correct —— 颜色标定模块(v14)
 用途: 标定流程 = 拍标准白纸 -> PC 抓帧算三通道比例 -> 改这里的
 parameter -> 编译。参数:
   SWAP_RB  : 1 = R/B 通道交换(Bayer 相位错配一键修)
   GAIN_R/G/B: Q8 增益(256=1.0x, 320=1.25x, 512=2.0x), 饱和到 255
 位置: cvp_awb 输出 -> 本模块 -> pack_4(100M 域, 1像素/拍, 2 级流水)
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
    wire       w_swap = I_swap_rt | (SWAP_RB && !I_swap_rt ? 1'b0 : 1'b0) | SWAP_RB;
    // swap 语义: 参数 SWAP_RB 与运行时位均可独立开启; 运行时位由命令直接控制
    wire       w_use_swap = I_swap_rt;
    wire [7:0] w_in_r = w_use_swap ? I_rgb[7:0]   : I_rgb[23:16];
    wire [7:0] w_in_g = I_rgb[15:8];
    wire [7:0] w_in_b = w_use_swap ? I_rgb[23:16] : I_rgb[7:0];
    wire [8:0] w_gr = (I_gain_r_rt != 9'd0) ? I_gain_r_rt : GAIN_R[8:0];
    wire [8:0] w_gg = (I_gain_g_rt != 9'd0) ? I_gain_g_rt : GAIN_G[8:0];
    wire [8:0] w_gb = (I_gain_b_rt != 9'd0) ? I_gain_b_rt : GAIN_B[8:0];

    // Q8 乘(8bit x 9bit = 17bit, 取 [16:9]), 饱和 255
    wire [16:0] w_mul_r = w_in_r * w_gr;
    wire [16:0] w_mul_g = w_in_g * w_gg;
    wire [16:0] w_mul_b = w_in_b * w_gb;

    wire [7:0] w_sat_r = (w_gr > 9'd256 && w_mul_r[16:9] > 8'd255) ? 8'hFF : w_mul_r[16:9];
    wire [7:0] w_sat_g = (w_gg > 9'd256 && w_mul_g[16:9] > 8'd255) ? 8'hFF : w_mul_g[16:9];
    wire [7:0] w_sat_b = (w_gb > 9'd256 && w_mul_b[16:9] > 8'd255) ? 8'hFF : w_mul_b[16:9];

    // 减益(<=1.0x)时截断即可; 增益(>1.0x)时饱和
    wire [7:0] w_out_r = (w_gr <= 9'd256) ? w_mul_r[16:9] : w_sat_r;
    wire [7:0] w_out_g = (w_gg <= 9'd256) ? w_mul_g[16:9] : w_sat_g;
    wire [7:0] w_out_b = (w_gb <= 9'd256) ? w_mul_b[16:9] : w_sat_b;

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
