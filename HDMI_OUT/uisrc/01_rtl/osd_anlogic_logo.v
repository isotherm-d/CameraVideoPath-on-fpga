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
    reg         hit_b = 0;
    reg [8:0]   rom_q = 9'h000;
    reg [7:0]   idx_b = 0;

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
            idx_b <= 8'h00;
        end else begin
            hit_b <= hit_a;
            idx_b <= rom_q[7:0];
        end
    end
    always @(posedge I_clk) rom_q <= mem[addr_a];

    /* 三级: 调色板 + alpha 选通 */
    function [23:0] pal(input [7:0] i);
        begin
            case (i)
8'h00: pal = 24'h1c2d4e;
8'h01: pal = 24'hed1c24;
8'h02: pal = 24'hf01e26;
8'h03: pal = 24'hf01c25;
8'h04: pal = 24'hee1c24;
8'h05: pal = 24'hf77e81;
8'h06: pal = 24'hfa797d;
8'h07: pal = 24'hef1e26;
8'h08: pal = 24'h1c2d4f;
8'h09: pal = 24'hf47579;
8'h0a: pal = 24'hef1c24;
8'h0b: pal = 24'h5b6579;
8'h0c: pal = 24'hf5646a;
8'h0d: pal = 24'hfa8084;
8'h0e: pal = 24'hf57276;
8'h0f: pal = 24'hf78a8c;
8'h10: pal = 24'hf12027;
8'h11: pal = 24'hf96b70;
8'h12: pal = 24'hef2027;
8'h13: pal = 24'hf58386;
8'h14: pal = 24'hf5595f;
8'h15: pal = 24'hf11d25;
8'h16: pal = 24'hfb8c90;
8'h17: pal = 24'hef1d25;
8'h18: pal = 24'hf5666a;
8'h19: pal = 24'h1d2e4f;
8'h1a: pal = 24'hf2222a;
8'h1b: pal = 24'h1e2f50;
8'h1c: pal = 24'hf89698;
8'h1d: pal = 24'h203050;
8'h1e: pal = 24'hf96065;
8'h1f: pal = 24'h838999;
8'h20: pal = 24'hf69193;
8'h21: pal = 24'h1f3051;
8'h22: pal = 24'hef2129;
8'h23: pal = 24'hf54e55;
8'h24: pal = 24'h203151;
8'h25: pal = 24'h233454;
8'h26: pal = 24'h3b4965;
8'h27: pal = 24'h203152;
8'h28: pal = 24'h203051;
8'h29: pal = 24'h1f3050;
8'h2a: pal = 24'h253555;
8'h2b: pal = 24'h334260;
8'h2c: pal = 24'h394764;
8'h2d: pal = 24'h354461;
8'h2e: pal = 24'hf12028;
8'h2f: pal = 24'h7c8596;
8'h30: pal = 24'hc9ccd2;
8'h31: pal = 24'h2a3a59;
8'h32: pal = 24'hc7cad0;
8'h33: pal = 24'h263656;
8'h34: pal = 24'hc3c7ce;
8'h35: pal = 24'h223353;
8'h36: pal = 24'hcdcfd5;
8'h37: pal = 24'h213252;
8'h38: pal = 24'hccced4;
8'h39: pal = 24'h3a4864;
8'h3a: pal = 24'hf1222a;
8'h3b: pal = 24'h798294;
8'h3c: pal = 24'h2b3b59;
8'h3d: pal = 24'h798193;
8'h3e: pal = 24'hc6c9d0;
8'h3f: pal = 24'h767f91;
8'h40: pal = 24'hd8dade;
8'h41: pal = 24'h727c8f;
8'h42: pal = 24'h233353;
8'h43: pal = 24'hfb9a9d;
8'h44: pal = 24'hcccfd5;
8'h45: pal = 24'h5f697f;
8'h46: pal = 24'hf21f27;
8'h47: pal = 24'hf62c34;
8'h48: pal = 24'h7f8798;
8'h49: pal = 24'h263757;
8'h4a: pal = 24'h8d94a3;
8'h4b: pal = 24'h3c4a65;
8'h4c: pal = 24'hee1d25;
8'h4d: pal = 24'h213152;
8'h4e: pal = 24'h808898;
8'h4f: pal = 24'h213253;
8'h50: pal = 24'h838b9b;
8'h51: pal = 24'hfcd9da;
8'h52: pal = 24'h7d8596;
8'h53: pal = 24'h394763;
8'h54: pal = 24'hfab2b4;
8'h55: pal = 24'h7e8697;
8'h56: pal = 24'h7b8394;
8'h57: pal = 24'hf1242c;
8'h58: pal = 24'hcbced4;
8'h59: pal = 24'hfcdedf;
8'h5a: pal = 24'hf54b51;
8'h5b: pal = 24'hfaacae;
8'h5c: pal = 24'h364461;
8'h5d: pal = 24'hc4c7ce;
8'h5e: pal = 24'h344360;
8'h5f: pal = 24'hcacdd3;
8'h60: pal = 24'h2f3f5d;
8'h61: pal = 24'hfab8ba;
8'h62: pal = 24'hb9bdc6;
8'h63: pal = 24'h2d3d5b;
8'h64: pal = 24'hc9cbd2;
8'h65: pal = 24'h2c3c5a;
8'h66: pal = 24'heaebed;
8'h67: pal = 24'h384663;
8'h68: pal = 24'h1c2e4f;
8'h69: pal = 24'he9eaec;
8'h6a: pal = 24'hfa7176;
8'h6b: pal = 24'habb0ba;
8'h6c: pal = 24'hf4343a;
8'h6d: pal = 24'hfac1c3;
8'h6e: pal = 24'hc8cbd1;
8'h6f: pal = 24'h374663;
8'h70: pal = 24'he3e4e7;
8'h71: pal = 24'h9fa5b1;
8'h72: pal = 24'he2e4e7;
8'h73: pal = 24'h4f5b74;
8'h74: pal = 24'h364562;
8'h75: pal = 24'h1d2e4e;
8'h76: pal = 24'he2e3e6;
8'h77: pal = 24'h606a80;
8'h78: pal = 24'h2f3e5c;
8'h79: pal = 24'h999fac;
8'h7a: pal = 24'hdddee2;
8'h7b: pal = 24'h9ba2ae;
8'h7c: pal = 24'h959ba9;
8'h7d: pal = 24'hf8676c;
8'h7e: pal = 24'h48556f;
8'h7f: pal = 24'h223354;
8'h80: pal = 24'hdfe1e4;
8'h81: pal = 24'hd6d8dd;
8'h82: pal = 24'h47546e;
8'h83: pal = 24'h778092;
8'h84: pal = 24'h959ca9;
8'h85: pal = 24'h243555;
8'h86: pal = 24'h424f6a;
8'h87: pal = 24'hc6c9cf;
8'h88: pal = 24'h404e69;
8'h89: pal = 24'he5e6e9;
8'h8a: pal = 24'hb6bac3;
8'h8b: pal = 24'hc5c8cf;
8'h8c: pal = 24'hdadce0;
8'h8d: pal = 24'h334360;
8'h8e: pal = 24'h45526c;
8'h8f: pal = 24'h8e95a3;
8'h90: pal = 24'h223253;
8'h91: pal = 24'h737d90;
8'h92: pal = 24'h8c93a2;
8'h93: pal = 24'ha3a9b5;
8'h94: pal = 24'h283858;
8'h95: pal = 24'h1d2e50;
8'h96: pal = 24'he6e7ea;
8'h97: pal = 24'hc2c6cd;
8'h98: pal = 24'h1d2f50;
8'h99: pal = 24'hc1c4cc;
8'h9a: pal = 24'h717b8f;
8'h9b: pal = 24'h677186;
8'h9c: pal = 24'hf32b32;
8'h9d: pal = 24'h1e2f51;
8'h9e: pal = 24'hc2c5cd;
8'h9f: pal = 24'h32425f;
8'ha0: pal = 24'h707a8e;
8'ha1: pal = 24'h293958;
8'ha2: pal = 24'h324160;
8'ha3: pal = 24'he8e9eb;
8'ha4: pal = 24'hd8d9dd;
8'ha5: pal = 24'hd3d4d8;
8'ha6: pal = 24'hfcd5d5;
8'ha7: pal = 24'hf88688;
8'ha8: pal = 24'hf87e82;
8'ha9: pal = 24'hfba9ab;
8'haa: pal = 24'hd6d9dd;
8'hab: pal = 24'hf8575d;
8'hac: pal = 24'hf11e26;
8'had: pal = 24'hfaabae;
8'hae: pal = 24'hf9a6a9;
8'haf: pal = 24'hf2282f;
8'hb0: pal = 24'hf75d62;
8'hb1: pal = 24'hced0d6;
8'hb2: pal = 24'h43516b;
8'hb3: pal = 24'hd5d7dc;
8'hb4: pal = 24'hf6565b;
8'hb5: pal = 24'hf32a32;
8'hb6: pal = 24'hfaaeb0;
8'hb7: pal = 24'h7f8797;
8'hb8: pal = 24'h8990a0;
8'hb9: pal = 24'hf9a3a5;
8'hba: pal = 24'hf3272f;
8'hbb: pal = 24'hf75d63;
8'hbc: pal = 24'h414e6a;
8'hbd: pal = 24'hd3d5da;
8'hbe: pal = 24'hfb8c8f;
8'hbf: pal = 24'hfb7a7f;
8'hc0: pal = 24'hfbbfc1;
8'hc1: pal = 24'h868d9d;
8'hc2: pal = 24'hcdd0d5;
8'hc3: pal = 24'h3f4c68;
8'hc4: pal = 24'hd0d3d8;
8'hc5: pal = 24'h818999;
8'hc6: pal = 24'h3d4a66;
8'hc7: pal = 24'hcfd1d6;
8'hc8: pal = 24'h7f8799;
8'hc9: pal = 24'h818898;
8'hca: pal = 24'hcccfd4;
8'hcb: pal = 24'hf89b9d;
8'hcc: pal = 24'hf57579;
8'hcd: pal = 24'hf77f82;
8'hce: pal = 24'hf99ea0;
8'hcf: pal = 24'hf2272e;
8'hd0: pal = 24'hf86166;
8'hd1: pal = 24'hccced3;
8'hd2: pal = 24'hcaccd2;
8'hd3: pal = 24'hfcdfe0;
8'hd4: pal = 24'hf54e53;
8'hd5: pal = 24'hf32c33;
8'hd6: pal = 24'hf89b9e;
8'hd7: pal = 24'hf76167;
8'hd8: pal = 24'h384562;
8'hd9: pal = 24'hc7c9d0;
8'hda: pal = 24'hf42d34;
8'hdb: pal = 24'hfab3b5;
8'hdc: pal = 24'h788092;
8'hdd: pal = 24'hf7666c;
8'hde: pal = 24'hf6646a;
8'hdf: pal = 24'hfa898d;
8'he0: pal = 24'h757d8f;
8'he1: pal = 24'hc0c3cb;
8'he2: pal = 24'h6f788c;
8'he3: pal = 24'h31415e;
8'he4: pal = 24'hbdc1c8;
8'he5: pal = 24'h7d8496;
8'he6: pal = 24'h6b7589;
8'he7: pal = 24'hfacdce;
8'he8: pal = 24'hfb8689;
8'he9: pal = 24'hfb8185;
8'hea: pal = 24'hfab5b8;
8'heb: pal = 24'hcbced3;
8'hec: pal = 24'hbabfc7;
8'hed: pal = 24'hfcd8d8;
8'hee: pal = 24'hf6454b;
8'hef: pal = 24'hf11c25;
8'hf0: pal = 24'hf52f36;
8'hf1: pal = 24'h677287;
8'hf2: pal = 24'hf88d90;
8'hf3: pal = 24'hf6676c;
8'hf4: pal = 24'h394864;
8'hf5: pal = 24'h2e3d5c;
8'hf6: pal = 24'hfcd7d8;
8'hf7: pal = 24'hf54349;
8'hf8: pal = 24'hf22e36;
8'hf9: pal = 24'hfababc;
8'hfa: pal = 24'h667085;
8'hfb: pal = 24'hf88e91;
8'hfc: pal = 24'hf6696e;
8'hfd: pal = 24'hc9ccd3;
8'hfe: pal = 24'hb6bac4;
8'hff: pal = 24'hfcddde;
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
                if (hit_b && rom_q[8]) O_rgb <= pal(idx_b);
                else O_rgb <= vid_d3;
            end
        end
    end

endmodule
