`timescale 1ns / 1ps
/*=============================================================================
 * osd_anlogic_logo —— 右上角安路 logo 叠加
 *
 * 参照 lab_ex3_osd_SC500_720P 的 hdmi_mixer logo 窗口(logo ROM + alpha 选通),
 * 精简为独立叠加模块, 插在 uidbuf 读出口与 RGB 输出寄存之间。
 *
 *   视频流(R_data)与 logo ROM 按像素叠加: ROM 位 24=1 的像素显示 logo 色,
 *   位 24=0(透明)透传视频。输出相对输入固定延迟 2 个像素时钟。
 *
 * 位置: 右上角 X_POS=1096, Y_POS=24 (160x160 logo, 边距 24/右留 24)。
 *===========================================================================*/
`timescale 1ns / 1ps
module osd_anlogic_logo #(
    parameter IMG_WIDTH = 1280,
    parameter LOGO_W    = 160,
    parameter LOGO_H    = 160,
    parameter X_POS     = 1096,     // 右上角: IMG_WIDTH - LOGO_W - 24
    parameter Y_POS     = 24
)(
    input  wire        I_clk,      // pclkx1 75M 像素钟
    input  wire        I_rst_n,
    input  wire        I_vs,       // 场同步(y 计数复位)
    input  wire        I_de,       // 有效像素选通
    input  wire [23:0] I_rgb,      // 视频像素(uidbuf R_data[23:0])
    output reg  [23:0] O_rgb,      // 叠加后像素
    output reg         O_de        // 对齐后的行有效(延迟 2 拍)
);
    localparam X_END = X_POS + LOGO_W;
    localparam Y_END = Y_POS + LOGO_H;

    reg [11:0] x_cnt = 0;
    reg [11:0] y_cnt = 0;
    reg        de_d = 0;
    wire       in_logo_c = I_de && (x_cnt >= X_POS) && (x_cnt < X_END) &&
                           (y_cnt >= Y_POS) && (y_cnt < Y_END);
    wire [15:0] logo_ofs_c = (y_cnt - Y_POS) * LOGO_W + (x_cnt - X_POS);
    reg         in_logo_r = 0;
    reg [14:0]  rom_addr_r = 0;
    reg [23:0]  vid_d1 = 0;
    reg         de_d1 = 0;
    wire [24:0] rom_q;

    anlogic_logo_rom u_logo_rom (.I_addr(rom_addr_r), .O_pixel(rom_q));

    /* 行/场计数 */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            x_cnt <= 0; y_cnt <= 0; de_d <= 0;
        end else begin
            de_d <= I_de;
            if (I_vs) y_cnt <= 0;
            else if (de_d && !I_de) y_cnt <= y_cnt + 1'b1;   // 行尾
            if (I_de) x_cnt <= x_cnt + 1'b1;
            else x_cnt <= 0;
        end
    end

    /* 一级: 窗口判定 + ROM 地址寄存 */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            in_logo_r <= 1'b0;
            rom_addr_r <= 15'd0;
            vid_d1 <= 24'd0;
            de_d1 <= 1'b0;
        end else begin
            in_logo_r  <= in_logo_c;
            rom_addr_r <= logo_ofs_c[14:0];
            vid_d1     <= I_rgb;
            de_d1      <= I_de;
        end
    end

    /* 二级: alpha 选通输出 */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            O_rgb <= 24'd0;
            O_de <= 1'b0;
        end else begin
            O_de <= de_d1;
            if (de_d1) begin
                if (in_logo_r && rom_q[24]) O_rgb <= rom_q[23:0];
                else O_rgb <= vid_d1;
            end
        end
    end

endmodule
