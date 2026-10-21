`timescale 1ns / 1ns
/*****************************************************************
 group_fifo —— 跨域组缓冲(v13d): 40.2MHz 写(突发) -> 100MHz 读(齿轮箱)
 v13b/c 失败根因: raw10 组流准连续(行间近无间隙), 40.2MHz 域内齿轮箱
 5拍/组(8M组/s)跟不上突发段写入(40.2M组/s), FIFO 积压溢出丢组(实测 58%
 吞吐, tuser 也丢)。
 v13d: cvp ISP 整体搬 100MHz(原设计时钟)。本 FIFO 跨域 Gray 指针,
 读侧 100M 下齿轮箱 5拍/组 = 20M 组/s 消化能力; 突发段(100M 时基
 每 ~2.5 拍 1 组)积压约段长一半, 2048 深覆盖数行连发; 行/帧间隙消化。
 读节律 5 拍(齿轮箱收1+弹4), 追空后保守空判决 3-4 拍恢复 < 5 拍, 无损。
*****************************************************************/
module group_fifo (
    input          I_wr_clk,
    input          I_wr_rst_n,
    input          I_wr_valid,
    input  [39:0]  I_wr_data,
    input          I_wr_tuser,
    input          I_wr_tlast,

    input          I_rd_clk,
    input          I_rd_rst_n,
    output         O_rd_valid,
    output [39:0]  O_rd_data,
    output         O_rd_tuser,
    output         O_rd_tlast
);

    wire        w_full;
    wire [41:0] w_rd_word;
    wire        w_rd_empty;
    wire        r_rd_en;

    cvp_async_fifo #(
        .DATA_WIDTH (42),
        .ADDR_WIDTH (11)          // 2048 深
    ) u_xfifo (
        .wr_clk   (I_wr_clk),
        .wr_rst_n (I_wr_rst_n),
        .wr_en    (I_wr_valid),   // 满则丢(读侧能力验算下不应发生)
        .wr_data  ({I_wr_tuser, I_wr_tlast, I_wr_data}),
        .wr_full  (w_full),
        .wr_level (),
        .wr_flush (1'b0),
        .rd_clk   (I_rd_clk),
        .rd_rst_n (I_rd_rst_n),
        .rd_en    (r_rd_en),
        .rd_data  (w_rd_word),
        .rd_valid (O_rd_valid),
        .rd_empty (w_rd_empty),
        .rd_flush (1'b0)
    );

    assign O_rd_data  = w_rd_word[39:0];
    // Packing is {frame_start, line_last, data}; do not exchange the two tags.
    assign O_rd_tuser = w_rd_word[41];
    assign O_rd_tlast = w_rd_word[40];

    /* ---- 读节律: 5 拍/组(齿轮箱收组 1 拍 + 弹出 4 拍) ---- */
    reg [2:0] r_gap;
    assign r_rd_en = !w_rd_empty && (r_gap == 3'd0);

    always @(posedge I_rd_clk or negedge I_rd_rst_n) begin
        if (!I_rd_rst_n)
            r_gap <= 3'd0;
        else if (r_rd_en)
            r_gap <= 3'd4;              // 读后隔 4 拍(共 5 拍周期)
        else if (r_gap != 3'd0)
            r_gap <= r_gap - 3'd1;
    end

endmodule
