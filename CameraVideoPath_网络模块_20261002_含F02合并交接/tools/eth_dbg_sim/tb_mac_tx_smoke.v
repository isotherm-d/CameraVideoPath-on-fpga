/*
 * tb_mac_tx_smoke —— cvp_gmii_mac_tx 冒烟仿真
 *
 * 真实 cvp_async_fifo + cvp_gmii_mac_tx；生产者写 2 包已知图案，给 2 块信用；
 * 从 dut.r_out_d/r_out_e（线上字节的两级寄存）抓 2 帧完整以太网帧写入
 * mac_out.bin，由 tools/eth_dbg_sim/verify_mac_out.py 按协议逐字段校验
 * （以太网/IP/UDP 头、IP 校验和、应用头、payload 图案、CRC32/FCS 字节序）。
 */
`timescale 1ns/1ps
module tb_mac_tx_smoke;

    localparam integer DATA_BYTES     = 1440;
    localparam integer PKTS_PER_FRAME = 1920;
    localparam integer NBYTES         = DATA_BYTES * 2;   // 2 包
    localparam integer CAP_PER_FRAME  = 1500;             // TX_EN 覆盖 前导8 + 帧1492（含FCS）

    reg clk125 = 1'b0;
    reg clk75  = 1'b0;
    always #4  clk125 = ~clk125;      // 125MHz
    always #6.67 clk75 = ~clk75;      // ~75MHz

    reg rst = 1'b1;
    reg [6:0] credit_gray = 7'd0;

    /* FIFO（与工程一致） */
    reg         wr_en = 1'b0;
    reg  [7:0]  wr_data = 8'd0;
    wire        wr_full;
    wire        rd_en, rd_valid, rd_empty;
    wire [7:0]  rd_data;
    wire [3:0]  pin_txd;
    wire        pin_ctl, pin_txc;

    cvp_async_fifo #(
        .DATA_WIDTH (8),
        .ADDR_WIDTH (13)
    ) u_fifo (
        .wr_clk   (clk75),
        .wr_rst_n (~rst),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full),
        .wr_level (),
        .wr_flush (1'b0),
        .rd_clk   (clk125),
        .rd_rst_n (~rst),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_valid (rd_valid),
        .rd_empty (rd_empty),
        .rd_flush (1'b0)
    );

    cvp_gmii_mac_tx #(
        .DATA_BYTES     (DATA_BYTES),
        .PKTS_PER_FRAME (PKTS_PER_FRAME)
    ) dut (
        .i_clk         (clk125),
        .i_rst         (rst),
        .i_txd_swap    (1'b0),
        .i_dbg_flags  (16'h0000),
        .i_credit_gray (credit_gray),
        .o_rd_en       (rd_en),
        .i_rd_empty    (rd_empty),
        .i_rd_valid    (rd_valid),
        .i_rd_data     (rd_data),
        .o_rgmii_txd   (pin_txd),
        .o_rgmii_tx_ctl(pin_ctl),
        .o_rgmii_txc   (pin_txc),
        .o_tx_pkt      ()
    );

    /* 生产者：75M 域连发 NBYTES 字节图案 */
    function [7:0] pattern;
        input integer i;
        begin
            pattern = (i * 7 + 13) & 8'hFF;
        end
    endfunction

    integer wr_i = 0;
    always @(posedge clk75) begin
        if (!rst && wr_i < NBYTES) begin
            wr_en   <= 1'b1;
            wr_data <= pattern(wr_i);
            wr_i    <= wr_i + 1;
        end else begin
            wr_en <= 1'b0;
        end
    end

    /* 引脚级抓包（模拟 PHY 内部 2ns 延时采样）：沿后 2ns 取引脚值，
     * 同一 TXC 周期 {Falling=高半字节, Rising=低半字节} 拼字节。
     * 完整走 ODDR → 验证 d0/d1 映射、negedge 重注册与 TXC 相位。 */
    reg [7:0] cap [0:2*CAP_PER_FRAME];
    integer cap_n = 0;
    reg [3:0] s_rise;
    reg       s_rise_en;
    always @(posedge clk125) begin
        #2;
        if (!rst) begin
            s_rise    = pin_txd;
            s_rise_en = pin_ctl;
        end
    end
    always @(negedge clk125) begin
        #2;
        if (!rst && pin_ctl && s_rise_en && cap_n < 2 * CAP_PER_FRAME) begin
            cap[cap_n] = {pin_txd, s_rise};
            cap_n      = cap_n + 1;
        end
    end

    integer f, i;
    initial begin
        rst = 1'b1;
        repeat (10) @(posedge clk125);
        rst = 1'b0;
        wait (wr_i == NBYTES);
        repeat (100) @(posedge clk75);
        credit_gray <= 7'd3;          // gray(2) = 3：放行 2 包
        wait (cap_n >= 2 * CAP_PER_FRAME);
        repeat (200) @(posedge clk125);
        f = $fopen("mac_out.bin", "wb");
        for (i = 0; i < cap_n; i = i + 1)
            $fwrite(f, "%c", cap[i]);
        $fclose(f);
        $display("SMOKE_DONE cap_n=%0d", cap_n);
        $finish;
    end

    initial begin
        #1000000;
        $display("SMOKE_TIMEOUT cap_n=%0d wr_i=%0d", cap_n, wr_i);
        $finish;
    end

endmodule
