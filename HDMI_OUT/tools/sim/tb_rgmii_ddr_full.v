`timescale 1ns / 1ps
/*=============================================================================
 * tb_rgmii_ddr —— RGMII 引脚级 DDR 仿真: 含 rgmii_interface(PLL2 相移采样 +
 * EG_LOGIC_IDDR + 字节拼装) 的完整接收链路
 *
 *   RGMII 4bit DDR 激励(仿无延迟 strap PHY: 数据随 RXC 沿翻转)
 *     → rgmii_interface (clk1 = RXC 滞后 2ns 采样) → rgmii_cdc → uiudp_stack
 *     → cvp_rx_assemble → 光栅逐字节比对
 *
 * 需编译安路仿真库: sim_release/eg/{eg_logic_io,eg_phy_pll}.v + common/al_phy_glbl.v
 * 运行: 见 run_ddr_sim.sh (plusargs 与 tb_cvp_net2vid 相同)
 *===========================================================================*/
`timescale 1ns/1ps
module tb_rgmii_ddr_full;

    localparam real    CLKP       = 8.0;               // 125MHz
    localparam integer IMG_W      = 1280;
    localparam integer IMG_H      = 720;
    localparam integer DBYTES     = 1440;
    localparam integer FRAMEBYTES = IMG_W*IMG_H*3;
    localparam integer FRAMEPX    = FRAMEBYTES/3;
    localparam integer MAXFRAMES  = 12;
    localparam integer TIMEOUT_NS = 400_000_000;

    reg clk125 = 0;
    reg rxc    = 0;                                     // PHY 恢复时钟
    always #(CLKP/2.0) clk125 = ~clk125;
    initial begin forever #(CLKP/2.0) rxc = ~rxc; end

    reg rst = 1;
    initial begin
        repeat (20) @(posedge clk125);
        rst = 0;
    end
    wire rst_n = ~rst;

    /* ---------------- 激励加载 ---------------- */
    reg [7:0]  stim_mem [0:32_000_000];
    integer    stim_len = 0, si = 0;
    reg [1023:0] stim_name, exp_name;
    reg        want_vcd = 0;
    integer    nframes_exp = 4, exp_bad = 0, skipfr = 0;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_name)) stim_name = "stim_clean.hex";
        if (!$value$plusargs("EXP=%s",  exp_name))  exp_name  = "exp_clean.hex";
        if (!$value$plusargs("NFRAMES=%d", nframes_exp)) nframes_exp = 4;
        if (!$value$plusargs("EXPBAD=%d",  exp_bad))     exp_bad     = 0;
        if (!$value$plusargs("SKIPFRAMES=%d", skipfr))   skipfr      = 0;
        want_vcd = $test$plusargs("VCD");
        $readmemh(stim_name, stim_mem);
        stim_len = 0;
        while (stim_len < 32_000_000 && stim_mem[stim_len] !== 8'hzz)
            stim_len = stim_len + 1;
        si = 0;
        $display("[TB] stim %0s: %0d beats", stim_name, stim_len);
    end

    /* ------------- behavioral RGMII PHY(无延迟 strap: 数据随 RXC 沿翻转) ------------- */
    reg        gmii_valid = 0;
    reg [7:0]  byte_r = 0;                          // 当前字节周期的字节(negedge 装载)
    reg [3:0]  rxd_r = 0;
    reg        ctl_r = 0;
    /* 正确的 RGMII 发射时序: negedge 装载下一字节并发射高 nibble,
     * posedge 发射低 nibble —— 字节内 [低|高] 两个半周期都来自同一字节。
     * (修复: 原驱动在 posedge 同时发低 nibble 并取新字节, 高 nibble 永远
     *  晚一拍, 拼出 {hi(下一字节), lo(当前字节)} 的交错流) */
    always @(negedge rxc) begin
        if (rst || !gmii_valid) begin
            rxd_r <= 4'h0; ctl_r <= 1'b0;
        end else begin
            rxd_r <= byte_r[7:4]; ctl_r <= 1'b1;
        end
        if (!rst) begin
            if (si < stim_len) begin
                if (stim_mem[si] === 8'hxx) begin
                    gmii_valid <= 1'b0; byte_r <= 8'h00;
                end else begin
                    gmii_valid <= 1'b1; byte_r <= stim_mem[si];
                end
                si <= si + 1;
            end else begin
                gmii_valid <= 1'b0;
            end
        end
    end
    always @(posedge rxc) begin
        if (rst || !gmii_valid) begin
            rxd_r <= 4'h0; ctl_r <= 1'b0;
        end else begin
            rxd_r <= byte_r[3:0]; ctl_r <= 1'b1;
        end
    end

    /* ---------------- DUT: rgmii_interface → 下游原链 ---------------- */
    wire        gmii_rx_clk, gmii_rx_sample_clk;
    wire [7:0]  gmii_rxd_w;
    wire        gmii_rx_dv_w, gmii_rx_er_w;
    wire        gmii_crs_w, gmii_col_w;
    wire        link_w; wire [1:0] spd_w; wire dup_w;
    wire [3:0]  rgmii_txd_w; wire rgmii_tx_ctl_w, rgmii_txc_w;
    wire [7:0]  rx_data, udp_rx_data, gmii_tdata, tx_data;
    wire        rx_valid, udp_rx_valid, gmii_tvalid, tx_valid;
    wire [15:0] crc_ok, crc_bad, lenbad;
    wire [11:0] cnt55, cntd5, cntaa, cnt5d;

    rgmii_interface #(.RX_CLK_PHASE_SEL(1)) u_rgmii_if (
        .speed_10_100   (1'b0),
        .gmii_tx_clk_d  (clk125),  .gmii_tx_reset_d(rst), .gmii_tx_reset(rst),
        .rgmii_txd      (rgmii_txd_w), .rgmii_tx_ctl(rgmii_tx_ctl_w), .rgmii_txc(rgmii_txc_w),
        .rgmii_rxd      (rxd_r),  .rgmii_rx_ctl(ctl_r), .rgmii_rxc(rxc),
        .gmii_tx_clk    (clk125),
        .gmii_txd       (8'h0),   .gmii_tx_en   (1'b0),  .gmii_tx_er(1'b0),
        .gmii_rx_reset  (rst),
        .gmii_rx_clk    (gmii_rx_clk),
        .gmii_rxd       (gmii_rxd_w), .gmii_rx_dv(gmii_rx_dv_w), .gmii_rx_er(gmii_rx_er_w),
        .gmii_crs       (gmii_crs_w), .gmii_col  (gmii_col_w),
        .link_status    (link_w), .clock_speed(spd_w), .duplex_status(dup_w),
        .o_dbg_cnt55(cnt55), .o_dbg_cntd5(cntd5), .o_dbg_cntaa(cntaa), .o_dbg_cnt5d(cnt5d),
        .o_gmii_rx_sample_clk(gmii_rx_sample_clk)
    );

    rgmii_cdc u_cdc (
        .speed_10_100 (1'b0),
        .I_rst        (rst),
        .I_gmii_rclk  (gmii_rx_sample_clk), .I_gmii_rvalid(gmii_rx_dv_w), .I_gmii_rdata(gmii_rxd_w),
        .I_gmii_tclk  (clk125),            .O_gmii_tvalid(gmii_tvalid),  .O_gmii_tdata(gmii_tdata),
        .I_rx_clk     (clk125),            .O_rx_valid   (rx_valid),     .O_rx_data   (rx_data),
        .I_tx_clk     (clk125),            .I_tx_valid   (tx_valid),     .I_tx_data   (tx_data)
    );

    uiudp_stack #(.CRC_GEN_EN(1'b1), .INTER_FRAME_GAP(4'd12)) u_stack (
        .I_uclk(clk125), .I_reset(rst),
        .I_mac_local_addr(48'h02_1A_2B_3C_4D_5F),
        .I_udp_local_port(16'd6000),
        .I_ip_local_addr ({8'd192,8'd168,8'd1,8'd100}),
        .I_udp_dest_port (16'd6000),
        .I_ip_dest_addr  ({8'd192,8'd168,8'd1,8'd66}),
        .O_W_udp_busy(), .I_W_udp_req(1'b0), .I_W_udp_valid(1'b0),
        .I_W_udp_data(8'h0), .I_W_udp_len(16'd0),
        .O_R_udp_valid(udp_rx_valid), .O_R_udp_data(udp_rx_data),
        .O_R_udp_len(), .O_R_udp_src_port(),
        .I_gmii_rclk (clk125), .I_gmii_rvalid(rx_valid), .I_gmii_rdata(rx_data),
        .I_gmii_tclk (clk125), .O_gmii_tvalid(tx_valid), .O_gmii_tdata(tx_data),
        .O_ip_rerror(), .O_mac_rerror(),
        .o_dbg_crc_ok(crc_ok), .o_dbg_crc_bad(crc_bad), .o_dbg_lenbad(lenbad)
    );

    wire        vidw_fs, vidw_de;
    wire [23:0] vidw_rgb;
    wire [7:0]  frame_cnt;

    cvp_rx_assemble #(.IMG_W(IMG_W), .IMG_H(IMG_H), .DATA_BYTES(DBYTES)) u_asm (
        .i_clk(clk125), .i_rst_n(rst_n),
        .i_udp_valid(udp_rx_valid), .i_udp_data(udp_rx_data),
        .o_w_fs(vidw_fs), .o_w_de(vidw_de), .o_w_rgb(vidw_rgb),
        .o_frame_cnt(frame_cnt), .o_pkt_act()
    );

    /* ---------------- 记分板(FS 上升沿分帧, 逐字节比对) ---------------- */
    reg [7:0] exp_mem [0:MAXFRAMES*FRAMEBYTES-1];
    integer   frames_seen = 0, pidx = 0, mismatches = 0, lenerr = 0, b;

    initial $readmemh(exp_name, exp_mem);

    reg fs_prev = 0;
    wire fs_rise = vidw_fs & ~fs_prev;
    always @(posedge clk125) fs_prev <= vidw_fs;

    always @(posedge clk125) begin
        if (!rst) begin
            if (vidw_de) begin
                if (pidx < FRAMEPX) begin
                    if (frames_seen >= skipfr) begin
                        for (b = 0; b < 3; b = b + 1) begin
                            if (exp_mem[(frames_seen-skipfr)*FRAMEBYTES + pidx*3 + b] !==
                                (b == 0 ? vidw_rgb[23:16] :
                                 b == 1 ? vidw_rgb[15:8] : vidw_rgb[7:0])) begin
                                mismatches = mismatches + 1;
                                if (mismatches <= 20)
                                    $display("[TB] frame=%0d px=%0d ch=%0d exp=%02x got=%02x",
                                             frames_seen, pidx, b,
                                             exp_mem[(frames_seen-skipfr)*FRAMEBYTES + pidx*3 + b],
                                             b == 0 ? vidw_rgb[23:16] :
                                             b == 1 ? vidw_rgb[15:8] : vidw_rgb[7:0]);
                            end
                        end
                    end
                end else begin
                    lenerr = lenerr + 1;
                end
                pidx = pidx + 1;
            end
            if (fs_rise) begin
                if (pidx !== FRAMEPX) begin
                    lenerr = lenerr + 1;
                    $display("[TB] frame=%0d pixel-count wrong: exp=%0d got=%0d",
                             frames_seen, FRAMEPX, pidx);
                end
                $display("[TB] frame %0d done: %0d px, total mismatches %0d",
                         frames_seen, pidx, mismatches);
                frames_seen = frames_seen + 1;
                pidx = 0;
                if (frames_seen == nframes_exp) begin
                    repeat (200) @(posedge clk125);
                    $display("[TB] ===== RESULT =====");
                    $display("[TB] frames     : %0d / %0d", frames_seen, nframes_exp);
                    $display("[TB] CRC ok/bad: %0d / %0d (exp bad=%0d)",
                             crc_ok, crc_bad, exp_bad);
                    if (mismatches == 0 && lenerr == 0 &&
                        frames_seen == nframes_exp && crc_bad == exp_bad)
                        $display("[TB] *** PASS ***");
                    else
                        $display("[TB] *** FAIL *** mismatches=%0d lenerr=%0d",
                                 mismatches, lenerr);
                    $finish;
                end
            end
        end
    end

    initial begin
        #TIMEOUT_NS;
        $display("[TB] *** FAIL *** timeout, frames=%0d/%0d", frames_seen, nframes_exp);
        $finish;
    end

    /* 心跳: 每 50us */
    always #(1_000_000) begin
        $display("[ST] t=%0t S=%0d pushed=%0d desc=%0d stUsed=%0d committed=%0d",
                 $time, u_asm.S_out, u_asm.r_pushed, u_asm.r_desc_cnt, u_asm.w_st_used,
                 u_asm.r_committed);
        $display("[HB] t=%0t ns cnt55lo=%0d cntd5lo=%0d crc=%0d/%0d MACSTATE=%0d DA=%h TYPE=%h CNT=%0d",
                 $time, cnt55, cntd5, crc_ok, crc_bad,
                 u_stack.mac_layer_inst.mac_rx_inst.STATE,
                 u_stack.mac_layer_inst.mac_rx_inst.dst_mac_addr,
                 u_stack.mac_layer_inst.mac_rx_inst.mac_frame_type,
                 u_stack.mac_layer_inst.mac_rx_inst.cnt);
    end

    initial if (want_vcd) begin
        $dumpfile("rgmii_full.vcd");
        $dumpvars(1, u_rgmii_if);
        $dumpvars(1, u_cdc);
        $dumpvars(1, u_asm);
    end

    /* 安路仿真库的全局复位模型(EG_LOGIC_IDDR 内部引用 glbl.gsrn) */
    glbl glbl();   // 实例名必须为 glbl(库内按根实例名 glbl.gsrn 引用)

endmodule
