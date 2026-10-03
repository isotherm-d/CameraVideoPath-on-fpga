/*
 * tb_eth_dbg_smoke —— cvp_eth_dbg 整链冒烟仿真
 *
 * 像素模型(75M, 带行消隐) → cvp_eth_dbg(真实 FIFO/信用/MAC) →
 * 抓 dut.u_mac 的线上两级寄存(r_out_d/r_out_e)写 eth_out.bin。
 * FRAME_SKIP=1：每帧都发；验证 2 个完整帧的应用头(frame_seq 递增/offset 归零)
 * 与 payload 图案：像素 n 的 RGB = {(n+1)%256,(n+2)%256,(n+3)%256}，
 * 即字节流第 m 字节 = (m/3 + 1 + m%3) & 0xFF。
 */
`timescale 1ns/1ps
module tb_eth_dbg_smoke;

    localparam integer IMG_W  = 1280;
    localparam integer IMG_H  = 720;
    localparam integer LINE_CYC = IMG_W + 100;      // 1280 有效 + 100 消隐
    localparam integer CAP_PER_FRAME = 1500;        // TX_EN 覆盖 前导8+帧1492（含FCS）
    localparam integer NFRAMES = 3;

    reg clk75 = 0, clk125 = 0, clk100 = 0;
    always #6.67 clk75  = ~clk75;
    always #4    clk125 = ~clk125;
    always #5    clk100 = ~clk100;

    reg rst75 = 1, rst125 = 1, rst100 = 1;

    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl, rgmii_txc;
    wire       mdc, mdio_o, mdio_oe, link, act, ext_dly;

    /* 像素模型信号（须先于 dut 例化声明，避免隐式线网冲突） */
    reg        w_valid = 1'b0;
    reg [23:0] w_rgb = 24'd0;
    integer fx = 0, lx = 0, px = 0;

    cvp_eth_dbg #(
        .IMG_W       (IMG_W),
        .IMG_H       (IMG_H),
        .FRAME_SKIP  (1),
        .GEN_TESTPAT (0)
    ) dut (
        .i_clk_pix    (clk75),
        .i_rst_pix_n  (~rst75),
        .i_valid      (w_valid),
        .i_rgb        (w_rgb),
        .i_clk_100m   (clk100),
        .i_rst_100m_n (~rst100),
        .i_clk_gmii   (clk125),
        .i_rst_gmii_n (~rst125),
        .i_txd_swap   (1'b0),
        .i_dbg_flags  (16'h0000),
        .o_rgmii_txd    (rgmii_txd),
        .o_rgmii_tx_ctl (rgmii_tx_ctl),
        .o_rgmii_txc    (rgmii_txc),
        .o_eth_mdc    (mdc),
        .o_eth_mdio_o (mdio_o),
        .o_eth_mdio_oe(mdio_oe),
        .i_eth_mdio_i (1'b1),
        .o_link       (link),
        .o_act        (act),
        .o_ext_dly    (ext_dly)
    );

    /* 像素模型：帧×行×有效像素，行间消隐
     * 像素 n 的 RGB = {(n+1)&FF, (n+2)&FF, (n+3)&FF} → 字节流第 m 字节 = (m/3+1+m%3)&FF */
    always @(posedge clk75) begin
        if (rst75) begin
            fx = 0; lx = 0; px = 0;
            w_valid <= 1'b0;
        end else begin
            if (px < IMG_W) begin
                w_valid   <= 1'b1;
                w_rgb     <= 24'h11_22_33;   // 常量图案：流=11 22 33 循环，验证 RGB 序+连续性
                px = px + 1;
            end else begin
                w_valid <= 1'b0;
                lx = lx + 1;
                px = 0;
                if (lx >= IMG_H) begin
                    lx = 0;
                    fx = fx + 1;
                end
            end
        end
    end

    /* 引脚级抓包（模拟 PHY 2ns 延时采样）：沿后 2ns 取值，同周期 {F=高,R=低} 拼字节 */
    reg [7:0] cap [0:2*CAP_PER_FRAME];
    integer cap_n = 0;
    reg [3:0] s_rise;
    reg       s_rise_en;
    always @(posedge clk125) begin
        #2;
        if (!rst125) begin
            s_rise    = rgmii_txd;
            s_rise_en = rgmii_tx_ctl;
        end
    end
    always @(negedge clk125) begin
        #2;
        if (!rst125 && rgmii_tx_ctl && s_rise_en && cap_n < 2 * CAP_PER_FRAME) begin
            cap[cap_n] = {rgmii_txd, s_rise};
            cap_n      = cap_n + 1;
        end
    end

    integer f, i;
    initial begin
        rst75 = 1; rst125 = 1; rst100 = 1;
        repeat (10) @(posedge clk75);
        rst75 = 0; rst125 = 0; rst100 = 0;
        wait (cap_n >= 2 * CAP_PER_FRAME);
        repeat (500) @(posedge clk125);
        f = $fopen("eth_out.bin", "wb");
        for (i = 0; i < cap_n; i = i + 1)
            $fwrite(f, "%c", cap[i]);
        $fclose(f);
        $display("ETH_SMOKE_DONE cap_n=%0d credits=%0d", cap_n, dut.r_credit_bin);
        $finish;
    end

    initial begin
        #400_000_000;   // 400ms 上限
        $display("ETH_SMOKE_TIMEOUT cap_n=%0d credits=%0d frames_done_px=%0d",
                 cap_n, dut.r_credit_bin, dut.r_px);
        $finish;
    end

endmodule
