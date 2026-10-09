`timescale 1ns / 1ps
/*=============================================================================
 * osd_anlogic_logo —— 右上角安路 logo 叠加(BRAM + $readmemh 版)
 *
 * logo 位图存 16384x9bit BRAM(裁剪内容框 146x94 + 256 色调色板索引),
 * $readmemh 上电初始化(文件: uisrc/01_rtl/logo_mem.hex, 绝对路径写在下方
 * $readmemh 处, 换机时同步修改)。
 *
 * 流水(3 拍, 视频同步延迟 3 拍):
 *   一级: 裁剪窗口判定 + BRAM 地址
 *   二级: BRAM 同步读 {alpha, 调色板索引}
 *   三级: 调色板查表 + alpha 选通输出
 *===========================================================================*/
`timescale 1ns / 1ps
module osd_anlogic_logo #(
    parameter IMG_WIDTH = 1280,
    parameter X_POS     = 1096,   // logo 框左上角(右上角: IMG_WIDTH-160-24)
    parameter Y_POS     = 24,
    parameter CROP_X    = 7,      // 内容框在 logo 内的偏移(实测 bounding box)
    parameter CROP_Y    = 34,
    parameter CROP_W    = 146,
    parameter CROP_H    = 94
)(
    input  wire        I_clk,      // pclkx1 75M
    input  wire        I_rst_n,
    input  wire        I_vs,       // 场同步(y 计数复位)
    input  wire        I_de,       // 有效像素选通
    input  wire [23:0] I_rgb,      // 视频像素(uidbuf R_data[23:0])
    output reg  [23:0] O_rgb,      // 叠加后像素
    output reg         O_de        // 对齐后的行有效(延迟 3 拍)
);
    localparam X_C0 = X_POS + CROP_X;   // 1103
    localparam Y_C0 = Y_POS + CROP_Y;   // 58
    localparam X_C1 = X_C0 + CROP_W;    // 1249
    localparam Y_C1 = Y_C0 + CROP_H;    // 152

    reg [11:0] x_cnt = 0;
    reg [11:0] y_cnt = 0;

    /* 像素坐标计数: I_de 期数 x, 行尾(de 拉低)进 y, I_vs 场清零 */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            x_cnt <= 12'd0;
            y_cnt <= 12'd0;
        end else if (I_vs) begin
            x_cnt <= 12'd0;
            y_cnt <= 12'd0;
        end else if (I_de) begin
            x_cnt <= x_cnt + 12'd1;
        end else if (x_cnt != 12'd0) begin
            x_cnt <= 12'd0;
            y_cnt <= y_cnt + 12'd1;
        end
    end

    wire       in_crop_c = I_de && (x_cnt >= X_C0) && (x_cnt < X_C1) &&
                           (y_cnt >= Y_C0) && (y_cnt < Y_C1);
    wire [13:0] bram_addr_c = (y_cnt - Y_C0) * CROP_W + (x_cnt - X_C0);
    reg         hit_a = 0;
    reg [13:0]  addr_a = 0;
    reg [23:0]  vid_d1 = 0, vid_d2 = 0, vid_d3 = 0;
    reg         de_d1 = 0, de_d2 = 0, de_d3 = 0;
    reg         hit_b = 0, hit_c = 0;
    reg [8:0]   rom_q = 9'h000, rom_q2 = 9'h000;

    /* logo BRAM: 16384x9 {alpha, 调色板索引}, $readmemh 初始化 */
    reg [8:0] mem [0:16383];
    initial $readmemh("C:/Users/cqm87/Desktop/2026/cvp/CameraVideoPath-on-fpga/HDMI_OUT/uisrc/01_rtl/logo_mem.hex", mem);

    /* 一级: 窗口/裁剪判定 + BRAM 地址 */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            hit_a <= 1'b0; addr_a <= 14'd0;
            vid_d1 <= 24'd0; vid_d2 <= 24'd0; vid_d3 <= 24'd0;
            de_d1 <= 1'b0; de_d2 <= 1'b0; de_d3 <= 1'b0;
        end else begin
            hit_a <= in_crop_c && (bram_addr_c < 14'd13724);
            addr_a <= bram_addr_c[13:0];
            vid_d1 <= I_rgb;   vid_d2 <= vid_d1;   vid_d3 <= vid_d2;
            de_d1 <= I_de;     de_d2 <= de_d1;     de_d3 <= de_d2;
        end
    end

    /* 二级: BRAM 同步读 {alpha, 调色板索引} (rom_q 唯一驱动在下方独立读出拍) */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            hit_b <= 1'b0;
        end else begin
            hit_b <= hit_a;
        end
    end
    always @(posedge I_clk) rom_q <= mem[addr_a];

    /* 三级: alpha/索引与视频对齐拍(修复: 原索引通路多一拍寄存导致颜色错位一像素) */
    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            hit_c <= 1'b0;
            rom_q2 <= 9'h000;
        end else begin
            hit_c <= hit_b;
            rom_q2 <= rom_q;
        end
    end

    /* 三级: 调色板 + alpha 选通 */
    function [23:0] pal(input [7:0] i);
        begin
            case (i)
8'h00: pal = 24'h1c2d4e;
8'h01: pal = 24'h1d2e50;
8'h02: pal = 24'h1e3050;
8'h03: pal = 24'h213252;
8'h04: pal = 24'h2b3b59;
8'h05: pal = 24'h313f5d;
8'h06: pal = 24'h31415e;
8'h07: pal = 24'h344360;
8'h08: pal = 24'h384663;
8'h09: pal = 24'h3b4965;
8'h0a: pal = 24'h3f4c68;
8'h0b: pal = 24'h414e69;
8'h0c: pal = 24'h44516c;
8'h0d: pal = 24'h48556e;
8'h0e: pal = 24'h4a5670;
8'h0f: pal = 24'h4d5a73;
8'h10: pal = 24'h525d76;
8'h11: pal = 24'h556178;
8'h12: pal = 24'h5a6579;
8'h13: pal = 24'h5f697f;
8'h14: pal = 24'h5f6a80;
8'h15: pal = 24'h626c82;
8'h16: pal = 24'h667186;
8'h17: pal = 24'h6e7687;
8'h18: pal = 24'h6b7588;
8'h19: pal = 24'h6f788c;
8'h1a: pal = 24'h717a8e;
8'h1b: pal = 24'h747e90;
8'h1c: pal = 24'h768092;
8'h1d: pal = 24'h7b8394;
8'h1e: pal = 24'h7f8798;
8'h1f: pal = 24'h828999;
8'h20: pal = 24'h898e9c;
8'h21: pal = 24'h8b909f;
8'h22: pal = 24'h8c93a2;
8'h23: pal = 24'h9096a5;
8'h24: pal = 24'h9399a7;
8'h25: pal = 24'h959ba9;
8'h26: pal = 24'h989eac;
8'h27: pal = 24'h9ba1ae;
8'h28: pal = 24'h9ea4b0;
8'h29: pal = 24'ha0a6b2;
8'h2a: pal = 24'ha4aab5;
8'h2b: pal = 24'ha9aeb8;
8'h2c: pal = 24'hadb1bb;
8'h2d: pal = 24'hb0b5bf;
8'h2e: pal = 24'hb2b6c0;
8'h2f: pal = 24'hb5b9c2;
8'h30: pal = 24'hb9bdc6;
8'h31: pal = 24'hbdc1c8;
8'h32: pal = 24'hc2c5cc;
8'h33: pal = 24'hc5c8ce;
8'h34: pal = 24'hc6c9d0;
8'h35: pal = 24'hcacdd3;
8'h36: pal = 24'hced0d6;
8'h37: pal = 24'hd0d2d7;
8'h38: pal = 24'hd3d5d9;
8'h39: pal = 24'hd6d8dc;
8'h3a: pal = 24'hd8d9de;
8'h3b: pal = 24'hdbdde1;
8'h3c: pal = 24'hdee0e3;
8'h3d: pal = 24'he1e3e6;
8'h3e: pal = 24'he5e6e9;
8'h3f: pal = 24'he7e8eb;
8'h40: pal = 24'hed1c24;
8'h41: pal = 24'hef2027;
8'h42: pal = 24'hef2129;
8'h43: pal = 24'he9e9ec;
8'h44: pal = 24'hf01d25;
8'h45: pal = 24'hf02027;
8'h46: pal = 24'hf12229;
8'h47: pal = 24'hf2282f;
8'h48: pal = 24'hf32c33;
8'h49: pal = 24'hf4343b;
8'h4a: pal = 24'hf43c42;
8'h4b: pal = 24'hf54046;
8'h4c: pal = 24'hf5444a;
8'h4d: pal = 24'hf54d54;
8'h4e: pal = 24'hf6565b;
8'h4f: pal = 24'hf5595f;
8'h50: pal = 24'hf75d62;
8'h51: pal = 24'hf76167;
8'h52: pal = 24'hf5646a;
8'h53: pal = 24'hf6696e;
8'h54: pal = 24'hf57276;
8'h55: pal = 24'hf47579;
8'h56: pal = 24'hf7797d;
8'h57: pal = 24'hf77e81;
8'h58: pal = 24'hf58386;
8'h59: pal = 24'hf68689;
8'h5a: pal = 24'hf78a8c;
8'h5b: pal = 24'hf69193;
8'h5c: pal = 24'hf94c52;
8'h5d: pal = 24'hf8575d;
8'h5e: pal = 24'hf86065;
8'h5f: pal = 24'hf8666b;
8'h60: pal = 24'hf96b70;
8'h61: pal = 24'hf97176;
8'h62: pal = 24'hfa7579;
8'h63: pal = 24'hf9797d;
8'h64: pal = 24'hf87d81;
8'h65: pal = 24'hf98084;
8'h66: pal = 24'hf98588;
8'h67: pal = 24'hf98a8d;
8'h68: pal = 24'hfa8c90;
8'h69: pal = 24'hf99092;
8'h6a: pal = 24'hf89698;
8'h6b: pal = 24'hf99a9c;
8'h6c: pal = 24'hfa9ea0;
8'h6d: pal = 24'hfaa2a5;
8'h6e: pal = 24'hf9a6a9;
8'h6f: pal = 24'hfaaaac;
8'h70: pal = 24'hfaaeb0;
8'h71: pal = 24'hfab1b3;
8'h72: pal = 24'hfab5b8;
8'h73: pal = 24'hfab9bb;
8'h74: pal = 24'hfbbfc0;
8'h75: pal = 24'hfac1c3;
8'h76: pal = 24'hfbcacb;
8'h77: pal = 24'hfbcfd0;
8'h78: pal = 24'hfbd2d3;
8'h79: pal = 24'hfcd7d8;
8'h7a: pal = 24'hfcdadb;
8'h7b: pal = 24'hfcdfe0;
8'h7c: pal = 24'hfde0e1;
            default: pal = 24'h000000;
            endcase
        end
    endfunction

    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            O_rgb <= 24'd0;
            O_de <= 1'b0;
        end else begin
            O_de <= de_d3;
            if (de_d3) begin
                if (hit_c && rom_q2[8]) O_rgb <= pal(rom_q2[7:0]);
                else O_rgb <= vid_d3;
            end
        end
    end

endmodule
