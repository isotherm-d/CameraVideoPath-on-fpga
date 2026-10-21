`timescale 1ns / 1ps
/*****************************************************************
@Description : 显示通路帧裁剪: 把 ISP 输出的 1280x720 RGB888 帧流
               居中裁出 1024x600, 供 7 寸 1024x600 DSI 屏显示。
               (DSI 屏物理分辨率固定 1024x600, 无法直显 720p 全幅)
               网口通路在 isp_top 的 O_awb_* 观测口取全幅 720p, 不经过本模块。
               数据为 128bit/拍 = 4 像素(RGB888), 与 video_in 接口一致。
*****************************************************************/

module rgb_frame_crop #(
    parameter IN_W    = 1280,   // 输入帧宽(像素)
    parameter IN_H    = 720,    // 输入帧高(像素)
    parameter OUT_W   = 1024,   // 裁剪输出宽(居中)
    parameter OUT_H   = 600,    // 裁剪输出高(居中)
    parameter PX_BEAT = 4       // 每拍像素数
)(
    input              I_clk,
    input              I_rst_n,

    input              I_tuser,     // 帧开始(输入流, 仅用于注释说明, 计数自同步)
    input              I_tvalid,
    input [PX_BEAT*24-1:0] I_tdata,

    output reg         O_tuser,     // 重新生成的帧开始(裁剪区第一拍)
    output reg         O_tvalid,
    output reg [PX_BEAT*24-1:0] O_tdata
);

    localparam IN_W_BEATS   = IN_W  / PX_BEAT;                // 320 拍/行
    localparam OUT_W_BEATS  = OUT_W / PX_BEAT;                // 256 拍/行
    localparam SKIP_L_BEATS = (IN_W  - OUT_W) / PX_BEAT / 2;  // 行首跳过 32 拍(128px)
    localparam SKIP_T_LINES = (IN_H  - OUT_H) / 2;            // 帧顶跳过 60 行

    reg [13:0] h_cnt;   // 行内拍计数
    reg [13:0] v_cnt;   // 行计数

    wire in_pass = (h_cnt >= SKIP_L_BEATS) && (h_cnt < SKIP_L_BEATS + OUT_W_BEATS)
                && (v_cnt >= SKIP_T_LINES) && (v_cnt < SKIP_T_LINES + OUT_H);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            h_cnt <= 'd0;
            v_cnt <= 'd0;
        end else if (I_tvalid) begin
            if (h_cnt == IN_W_BEATS - 1) begin
                h_cnt <= 'd0;
                v_cnt <= (v_cnt == IN_H - 1) ? 'd0 : v_cnt + 1'b1;
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    // 一帧恰好一个 tuser: 裁剪区的第一拍
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            {O_tuser, O_tvalid} <= 'd0;
            O_tdata             <= 'd0;
        end else begin
            O_tuser  <= I_tvalid && (h_cnt == SKIP_L_BEATS) && (v_cnt == SKIP_T_LINES);
            O_tvalid <= I_tvalid && in_pass;
            O_tdata  <= I_tdata;
        end
    end

endmodule
