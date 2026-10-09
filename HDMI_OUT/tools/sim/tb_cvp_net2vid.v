`timescale 1ns / 1ps
/*=============================================================================
 * tb_cvp_net2vid —— HDMI_OUT 网口→视频流链路 RTL 联合仿真
 *
 * 链路(与 cvp_hdmi_top 相同的例化参数):
 *   GMII字节流(采样钟域) → rgmii_cdc → uiudp_stack(MAC/IP/UDP) → cvp_rx_assemble
 *   (rgmii_interface 的 DDR 部分不在仿真范围, TB 直接在采样钟域注入字节)
 *
 * 激励: python make_vectors.py 生成的 stim_*.hex, 每行 1 字节,
 *       'xx'=空闲拍, 末尾 4 行 'zz'=终止符
 * 期望: exp_*.hex = 每个帧同步间隔的期望光栅(FRAME_BYTES 字节/帧, 首帧=上电黑帧)
 *
 * 运行: vsim -c work.tb_cvp_net2vid +STIM=stim_clean.hex +EXP=exp_clean.hex
 *           +NFRAMES=4 +EXPBAD=0 -do "run -all"   (+VCD 打开波形转储)
 *===========================================================================*/
`timescale 1ns/1ps
module tb_cvp_net2vid;

    localparam real    CLKP       = 8.0;               // 125MHz
    localparam integer IMG_W      = 480;
    localparam integer IMG_H      = 10;
    localparam integer DBYTES     = 1440;
    localparam integer FRAMEBYTES = IMG_W*IMG_H*3;      // 14400
    localparam integer FRAMEPX    = FRAMEBYTES/3;       // 4800
    localparam integer MAXFRAMES  = 8;
    localparam integer TIMEOUT_NS = 40_000_000;         // 40ms

    reg clk125 = 0;
    reg clkSmp = 0;                                     // PHY 采样钟(仿 PLL2 移相输出)
    always #(CLKP/2.0) clk125 = ~clk125;
    initial begin #1.0; forever #(CLKP/2.0) clkSmp = ~clkSmp; end

    reg rst = 1;
    initial begin
        repeat (20) @(posedge clk125);
        rst = 0;
    end
    wire rst_n = ~rst;

    /* ---------------- 激励加载与 GMII 字节流注入(采样钟域) ---------------- */
    reg [7:0]  stim_mem [0:1_000_000];
    integer    stim_len = 0, si = 0;
    reg        gmii_valid = 0;
    reg [7:0]  gmii_data  = 0;
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
        while (stim_len < 1_000_000 && stim_mem[stim_len] !== 8'hzz)
            stim_len = stim_len + 1;
        si = 0;
        $display("[TB] stim %0s: %0d beats", stim_name, stim_len);
    end

    always @(negedge clkSmp) begin
        if (rst) begin
            gmii_valid <= 1'b0;
        end else if (si < stim_len) begin
            if (stim_mem[si] === 8'hxx) begin
                gmii_valid <= 1'b0;
                gmii_data  <= 8'h00;
            end else begin
                gmii_valid <= 1'b1;
                gmii_data  <= stim_mem[si];
            end
            si <= si + 1;
        end else begin
            gmii_valid <= 1'b0;
        end
    end

    /* ---------------- DUT: rgmii_cdc → uiudp_stack → cvp_rx_assemble ---------------- */
    wire [7:0] rx_data, udp_rx_data, gmii_tdata, tx_data;
    wire       rx_valid, udp_rx_valid, gmii_tvalid, tx_valid;
    wire [15:0] crc_ok, crc_bad, lenbad;

    rgmii_cdc u_cdc (
        .speed_10_100 (1'b0),
        .I_rst        (rst),
        .I_gmii_rclk  (clkSmp),      .I_gmii_rvalid(gmii_valid), .I_gmii_rdata(gmii_data),
        .I_gmii_tclk  (clk125),      .O_gmii_tvalid(gmii_tvalid), .O_gmii_tdata(gmii_tdata),
        .I_rx_clk     (clk125),      .O_rx_valid   (rx_valid),    .O_rx_data   (rx_data),
        .I_tx_clk     (clk125),      .I_tx_valid   (tx_valid),    .I_tx_data   (tx_data)
    );

    uiudp_stack #(.CRC_GEN_EN(1'b1), .INTER_FRAME_GAP(4'd12)) u_stack (
        .I_uclk          (clk125),
        .I_reset         (rst),
        .I_mac_local_addr(48'h02_1A_2B_3C_4D_5F),
        .I_udp_local_port(16'd6000),
        .I_ip_local_addr ({8'd192,8'd168,8'd1,8'd100}),
        .I_udp_dest_port (16'd6000),
        .I_ip_dest_addr  ({8'd192,8'd168,8'd1,8'd66}),
        .O_W_udp_busy(), .I_W_udp_req(1'b0), .I_W_udp_valid(1'b0),
        .I_W_udp_data(8'h0), .I_W_udp_len(16'd0),
        .O_R_udp_valid(udp_rx_valid), .O_R_udp_data(udp_rx_data),
        .O_R_udp_len(), .O_R_udp_src_port(),
        .I_gmii_rclk (clk125),   .I_gmii_rvalid(rx_valid), .I_gmii_rdata(rx_data),
        .I_gmii_tclk (clk125),   .O_gmii_tvalid(tx_valid), .O_gmii_tdata(tx_data),
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

    /* ---------------- 记分板: FS 分帧逐字节比对 ---------------- */
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
                    lenerr = lenerr + 1;            // FS 前像素超帧长
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
                    $display("[TB] lenbad    : %0d (note: good frames also counted = window bug)",
                             lenbad);
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

    /* ---------------- 超时与波形 ---------------- */
    initial begin
        #TIMEOUT_NS;
        $display("[TB] *** FAIL *** timeout, frames=%0d/%0d", frames_seen, nframes_exp);
        $finish;
    end

    /* 心跳: 每 100us 打印重组器关键内部状态(不依赖 VCD/examine) */
    always #(100_000) begin
        $display("[PRM] FRAME_BYTES=%0d BYTE_W=%0d IMG_W=%0d IMG_H=%0d DESCW=%0d fcntHier=%0d",
                 u_asm.FRAME_BYTES, u_asm.BYTE_W, u_asm.IMG_W, u_asm.IMG_H,
                 u_asm.DESC_W, u_asm.o_frame_cnt);
        $display("[HB] t=%0t ns fcnt=%0d fs=%b de=%b S=%0d pushed=%0d tgt=%0d wcnt=%0d desc=%0d wr=%0d rd=%0d stUsed=%0d udpV=%b crc=%0d/%0d",
                 $time, frame_cnt, vidw_fs, vidw_de, u_asm.S_out,
                 u_asm.r_pushed, u_asm.r_target, u_asm.r_wcnt,
                 u_asm.r_desc_cnt, u_asm.r_desc_wr, u_asm.r_desc_rd, u_asm.w_st_used,
                 udp_rx_valid, crc_ok, crc_bad);
        $display("[Q] %0d:%h %0d:%h %0d:%h %0d:%h %0d:%h %0d:%h %0d:%h %0d:%h",
                 0, u_asm.r_desc[0], 1, u_asm.r_desc[1], 2, u_asm.r_desc[2], 3, u_asm.r_desc[3],
                 4, u_asm.r_desc[4], 5, u_asm.r_desc[5], 6, u_asm.r_desc[6], 7, u_asm.r_desc[7]);
    end

    initial if (want_vcd) begin
        $dumpfile("net2vid.vcd");
        $dumpvars(1, u_asm);
        $dumpvars(1, u_cdc);
        $dumpvars(1, u_stack.mac_layer_inst.mac_rx_inst);
    end

endmodule
