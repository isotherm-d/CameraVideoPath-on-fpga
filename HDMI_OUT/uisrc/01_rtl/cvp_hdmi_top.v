/*
 * ============================================================================
 * cvp_hdmi_top —— EG4D 副板顶层: 千兆网口收 PH1P35 视频流 → 片内DDR1 三缓冲
 *                → 1280x720@60 HDMI 输出
 *
 * 板卡: MLKPAI-F01 (EG4D20EG176, PHY=YT8531DH-CA RGMII, 片内合封 16MB DDR1,
 *       HDMI 由 LVDS 直连 TMDS)
 * 时钟(25M 晶振, 共用 4 个 PLL):
 *   pll_gmii : 25M → 125/125°90/25/25°90/12.5   (协议栈 + 重组器)
 *   PLL2(内) : PHY RXCK 清洗(rgmii_interface 内部)
 *   ddr_pll  : 25M → 150/150°90/150°180/25/50   (DDR1 控制器 + FDMA)
 *   clk_hdmi_pll: 25M → 75(像素)/375(TMDS serdes)
 *
 * 数据流:
 *   YT8531 RGMII → rgmii_interface → rgmii_cdc → uiudp_stack
 *     (MAC 层已改: 广播+IP 帧放行; IP 层过滤目的IP=192.168.1.100)
 *   → cvp_rx_assemble (UDP载荷→顺序光栅像素流, 丢包补黑, 30fps)
 *   → uidbuf 三缓冲 (1280x720 RGB888, W=125M域, R=75M域)
 *   → app_fdma → ddr1_as_ram → EG_PHY_DDR_8M_16 (合封 DDR1, 帧步进4MB, 3帧12.6MB)
 *   → uivtc(720p60) 读时序 → uihdmitx (EG4 TMDS) → HDMI
 *
 * 带宽: DDR1 峰值 600MB/s(150M DDR×16bit), 写 110.6 + 读 221.2 = 331.8MB/s(55%);
 *       若量产出现欠载, 将 uidbuf W/R_DATAWIDTH 降到 16(RGB565) 可减半。
 * ============================================================================
 */
module cvp_hdmi_top #(
    /* 1 = 内置彩条(分诊: 出彩条=HDMI链路OK, 问题在网口/DDR链; 不出=HDMI链路本身)
     * 0 = 网口视频流(正常工作模式) */
    parameter integer GEN_TESTPAT = 0
)(
    input  wire        I_sys_clk,       // 25MHz 晶振
    output wire        O_phy_rst,       // YT8531 复位(uiphyrst 时序)

    /* RGMII (YT8531) */
    input  wire [3:0]  I_rgmii_rxd,
    input  wire        I_rgmii_rx_ctl,
    input  wire        I_rgmii_rxc,
    output wire [3:0]  O_rgmii_txd,     // 本设计不发送, 恒空闲帧间隔
    output wire        O_rgmii_tx_ctl,
    output wire        O_rgmii_txc,

    /* HDMI (TMDS via LVDS, 仅 P 端, 例程23 同款) */
    output wire        O_HDMI_CLK_P,
    output wire [2:0]  O_HDMI_TX_P,

    /* 调试/心跳 LED:
     *   LED0(P91)  = 心跳, 烧录成功 ~1.5Hz 闪
     *   LED1(P104) = 收到UDP载荷(协议栈ETHB链路通的证据) ~2.6Hz 闪
     *   LED2(P109) = 重组器产出完整帧(o_fs 在发) ~1.9Hz 闪
     *   LED3(P112) = FDMA 实际写DDR(uidbuf写侧活着) ~1.9Hz 闪
     * 分诊: LED1灭=链路断; 1亮2灭=重组器卡; 1,2亮3灭=uidbuf没写;
     *       全亮仍杂色=数据错序(查字节序) */
    output wire [3:0]  O_led
);

    /* ================= 时钟 ================= */
    wire clk_125, clk_125_90, clk_25, clk_25_90, clk_12_5, pll_gmii_lock;
    wire ddr_clk0, ddr_clk90, ddr_clk180, ddr_25m, ddr_50m, ddr_pll_lock;
    wire pclkx1, pclkx5, hdmi_pll_lock, clk_hdmi_25m;

    pll pll_gmii_inst (
        .refclk    (I_sys_clk     ),
        .reset     (1'b0          ),
        .extlock   (pll_gmii_lock ),
        .clk0_out  (clk_125       ),
        .clk1_out  (clk_125_90    ),
        .clk2_out  (clk_25        ),
        .clk3_out  (clk_25_90     ),
        .clk4_out  (clk_12_5      )
    );

    ddr_pll u_ddr_pll (
        .refclk    (I_sys_clk     ),
        .reset     (1'b0          ),
        .extlock   (ddr_pll_lock  ),
        .clk0_out  (ddr_clk0      ),   // 150M
        .clk1_out  (ddr_clk90     ),   // 150M 90°
        .clk2_out  (ddr_clk180    ),   // 150M 180°
        .clk3_out  (ddr_25m       ),
        .clk4_out  (ddr_50m       )
    );

    clk_hdmi_pll u_hdmi_pll (
        .refclk    (I_sys_clk     ),
        .reset     (1'b0          ),
        .extlock   (hdmi_pll_lock ),
        .clk0_out  (clk_hdmi_25m  ),
        .clk1_out  (pclkx1        ),   // 75M 像素时钟
        .clk2_out  (pclkx5        )    // 375M serdes
    );

    /* ================= PHY 复位 + 协议栈复位(照抄 UDP 例程) ================= */
    wire phy_rst, phy_rst_done;

    uiphyrst #(
        .CLK_FREQ (32'd12_500_000)
    ) u_uiphyrst (
        .I_CLK        (clk_12_5     ),
        .I_rstn       (pll_gmii_lock),
        .I_phyrst     (pll_gmii_lock),
        .O_phyrst     (phy_rst      ),
        .O_phyrst_done(phy_rst_done )
    );
    assign O_phy_rst = phy_rst;

    reg [19:0] reset_cnt;
    reg        reset_syn1, reset_syn2;
    reg        stack_reset;                 // 高有效, clk_12_5 域产生
    always @(posedge clk_12_5 or negedge phy_rst) begin
        if (!phy_rst) reset_cnt <= 0;
        else if (reset_cnt <= 20'h000ff) reset_cnt <= reset_cnt + 1'b1;
    end
    always @(posedge clk_12_5 or negedge phy_rst) begin
        if (!phy_rst) begin
            reset_syn1 <= 1'b1; reset_syn2 <= 1'b1; stack_reset <= 1'b1;
        end else begin
            reset_syn1 <= (reset_cnt <= 20'h000ff);
            reset_syn2 <= reset_syn1;
            stack_reset <= reset_syn2;
        end
    end
    /* 打两拍进 125M 域 */
    reg stack_reset_125r1, stack_reset_125;
    always @(posedge clk_125 or negedge pll_gmii_lock) begin
        if (!pll_gmii_lock) begin
            stack_reset_125r1 <= 1'b1;
            stack_reset_125   <= 1'b1;
        end else begin
            stack_reset_125r1 <= stack_reset;
            stack_reset_125   <= stack_reset_125r1;
        end
    end

    /* ================= 视频时序/像素域信号(声明先于所有使用处) ================= */
    wire vid_vs, vid_hs, vid_de;
    wire [11:0] w_dbg_cnt55, w_dbg_cntd5, w_dbg_cntaa, w_dbg_cnt5d;
    wire [15:0] w_crc_ok, w_crc_bad;
    wire [15:0] w_lenbad;

    /* ================= RGMII → GMII → UDP 协议栈 ================= */
    wire gmii_rx_clk;
    wire gmii_rx_sample_clk;   /* CVP修: RX 采样域时钟(IDDR/字节流所在域) */
    wire [7:0] gmii_rdata, rx_data;
    wire       gmii_rvalid, rx_valid;
    wire       gmii_tvalid, tx_valid;
    wire [7:0] gmii_tdata, tx_data;
    wire       udp_rx_valid;
    wire [7:0] udp_rx_data;

    rgmii_interface u_rgmii_if (
        .speed_10_100   (1'b0          ),
        .gmii_tx_clk_d  (clk_125       ),
        .gmii_tx_reset_d(stack_reset_125),
        .gmii_tx_reset  (stack_reset_125),
        .gmii_tx_clk    (clk_125       ),
        .gmii_txd       (gmii_tdata    ),
        .gmii_tx_en     (gmii_tvalid   ),
        .gmii_tx_er     (              ),
        .gmii_rx_reset  (stack_reset_125),
        .gmii_rx_clk    (gmii_rx_clk   ),
        .gmii_rxd       (gmii_rdata    ),
        .gmii_rx_dv     (gmii_rvalid   ),
        .gmii_rx_er     (              ),
        .rgmii_txd      (O_rgmii_txd   ),
        .rgmii_tx_ctl   (O_rgmii_tx_ctl),
        .rgmii_txc      (O_rgmii_txc   ),
        .rgmii_rxd      (I_rgmii_rxd   ),
        .rgmii_rx_ctl   (I_rgmii_rx_ctl),
        .rgmii_rxc      (I_rgmii_rxc   ),
        .gmii_crs       (              ),
        .gmii_col       (              ),
        .link_status    (              ),
        .clock_speed    (              ),
        .duplex_status  (              ),
        .o_dbg_cnt55    (w_dbg_cnt55   ),
        .o_dbg_cntd5    (w_dbg_cntd5   ),
        .o_dbg_cntaa    (w_dbg_cntaa   ),
        .o_dbg_cnt5d    (w_dbg_cnt5d   ),
        .o_gmii_rx_sample_clk (gmii_rx_sample_clk)
    );

    rgmii_cdc u_rgmii_cdc (
        .speed_10_100 (1'b0           ),
        .I_rst        (stack_reset_125),
        .I_gmii_rclk  (gmii_rx_sample_clk),  /* CVP修: 与 gmii_rxd/rx_dv 同域 */
        .I_gmii_rvalid(gmii_rvalid    ),
        .I_gmii_rdata (gmii_rdata     ),
        .I_gmii_tclk  (clk_125        ),
        .O_gmii_tvalid(gmii_tvalid    ),
        .O_gmii_tdata (gmii_tdata     ),
        .I_rx_clk     (clk_125        ),
        .O_rx_valid   (rx_valid       ),
        .O_rx_data    (rx_data        ),
        .I_tx_clk     (clk_125        ),
        .I_tx_valid   (tx_valid       ),
        .I_tx_data    (tx_data        )
    );

    wire [15:0] udp_rx_len, udp_rx_sport;
    wire        udp_ip_rerr, udp_mac_rerr;

    uiudp_stack #(
        .CRC_GEN_EN      (1'b1           ),
        .INTER_FRAME_GAP (4'd12          )
    ) u_udp_stack (
        .I_uclk          (clk_125        ),
        .I_reset         (stack_reset_125),
        .I_mac_local_addr(48'h02_1A_2B_3C_4D_5F),  // 任意本地单播 MAC
        .I_udp_local_port(16'd6000       ),
        .I_ip_local_addr ({8'd192, 8'd168, 8'd1, 8'd100}),  // = PH1P35 流的 IP_DST
        .I_udp_dest_port (16'd6000       ),
        .I_ip_dest_addr  ({8'd192, 8'd168, 8'd1, 8'd66 }),
        .O_W_udp_busy    (               ),
        .I_W_udp_req     (1'b0           ),   // 纯接收, 永不发送
        .I_W_udp_valid   (1'b0           ),
        .I_W_udp_data    (8'd0           ),
        .I_W_udp_len     (16'd0          ),
        .O_R_udp_valid   (udp_rx_valid   ),
        .O_R_udp_data    (udp_rx_data    ),
        .O_R_udp_len     (udp_rx_len     ),
        .O_R_udp_src_port(udp_rx_sport   ),
        .I_gmii_rclk     (clk_125        ),
        .I_gmii_rvalid   (rx_valid       ),
        .I_gmii_rdata    (rx_data        ),
        .I_gmii_tclk     (clk_125        ),
        .O_gmii_tvalid   (tx_valid       ),
        .O_gmii_tdata    (tx_data        ),
        .O_ip_rerror     (udp_ip_rerr    ),
        .O_mac_rerror    (udp_mac_rerr   ),
        .o_dbg_crc_ok    (w_crc_ok       ),
        .o_dbg_crc_bad   (w_crc_bad      ),
        .o_dbg_lenbad    (w_lenbad       )
    );

    /* ================= UDP 载荷 → 光栅视频流 ================= */
    wire        vidw_fs, vidw_de;
    wire [23:0] vidw_rgb;
    wire [7:0]  rx_frame_cnt;

    cvp_rx_assemble #(
        .IMG_W      (1280    ),
        .IMG_H      (720     ),
        .DATA_BYTES (1440    )
    ) u_assemble (
        .i_clk       (clk_125        ),
        .i_rst_n     (~stack_reset_125),
        .i_udp_valid (udp_rx_valid   ),
        .i_udp_data  (udp_rx_data    ),
        .o_w_fs      (vidw_fs        ),
        .o_w_de      (vidw_de        ),
        .o_w_rgb     (vidw_rgb       ),
        .o_frame_cnt (rx_frame_cnt   ),
        .o_pkt_act   (               )
    );

    /* ================= 片内 DDR1 三缓冲 (例程25 链路) ================= */
    wire        sdr_init_done, sdr_init_ref_vld;
    wire        app_wr_en, app_rd_en, sdr_rd_en, sdr_busy;
    wire [22:0] app_wr_addr, app_rd_addr;
    wire [1:0]  app_wr_dm;
    wire [31:0] app_wr_din, sdr_rd_dout;

    wire [23:0] fdma_waddr, fdma_raddr;
    wire        fdma_wareq, fdma_rareq;
    wire [15:0] fdma_wsize, fdma_rsize;
    wire        fdma_wbusy, fdma_rbusy, fdma_wvalid, fdma_rvalid;
    wire [31:0] fdma_wdata, fdma_rdata;

    wire [7:0]  W_sync_cnt, rbuf_next;
    reg  [7:0]  R_buf;
    wire [31:0] R_data;   // uidbuf 32bit 通路, 像素在 [23:0]

    wire fdma_clk = ddr_clk0;
    wire fdma_rstn = sdr_init_done;

    uidbuf #(
        .VIDEO_ENABLE  (1     ),
        .ENABLE_WRITE  (1     ),
        .ENABLE_READ   (1     ),
        .AXI_DATA_WIDTH(32    ),
        .AXI_ADDR_WIDTH(24    ),
        .W_BUFDEPTH    (2048  ),
        .W_DATAWIDTH   (32    ),   // 32bit 通路: 24bit 会使 FIFO 深度=1536(BRAM 只允许 512/1k/2k/4k/8k)
        .W_BASEADDR    (0     ),
        .W_DSIZEBITS   (22    ),   // 帧步进 2^22B=4.19MB, 3帧共12.6MB < 16MB
        .W_XSIZE       (1280  ),
        .W_YSIZE       (720   ),
        .W_BUFSIZE     (3     ),
        .R_BUFDEPTH    (2048  ),
        .R_DATAWIDTH   (32    ),   // 读侧同理 32bit, 像素在 [23:0], 高 8bit 填 0
        .R_BASEADDR    (0     ),
        .R_DSIZEBITS   (22    ),
        .R_XSIZE       (1280  ),
        .R_YSIZE       (720   ),
        .R_BUFSIZE     (3     )
    ) u_uidbuf (
        .ui_clk      (fdma_clk ),
        .ui_rstn     (fdma_rstn),
        .W_wclk_i    (clk_125  ),    // 重组器输出域
        .W_FS_i      (vidw_fs  ),
        .W_wren_i    (vidw_de  ),
        .W_data_i    ({8'h00, vidw_rgb}),   // 每像素填 32bit {0,RGB888}
        .W_sync_cnt_o(W_sync_cnt),
        .W_buf_i     (W_sync_cnt),
        .W_full      (         ),
        .R_rclk_i    (pclkx1   ),    // HDMI 像素域
        .R_FS_i      (vid_vs   ),
        .R_rden_i    (vid_de   ),
        .R_data_o    (R_data   ),
        .R_sync_cnt_o(         ),
        .R_buf_i     (R_buf    ),
        .R_empty     (         ),
        .fdma_waddr  (fdma_waddr),
        .fdma_wareq  (fdma_wareq),
        .fdma_wsize  (fdma_wsize),
        .fdma_wbusy  (fdma_wbusy),
        .fdma_wdata  (fdma_wdata),
        .fdma_wvalid (fdma_wvalid),
        .fmda_wbuf   (         ),
        .fdma_wirq   (         ),
        .fdma_raddr  (fdma_raddr),
        .fdma_rareq  (fdma_rareq),
        .fdma_rsize  (fdma_rsize),
        .fdma_rbusy  (fdma_rbusy),
        .fdma_rdata  (fdma_rdata),
        .fdma_rvalid (fdma_rvalid),
        .fmda_rbuf   (         ),
        .fdma_rirq   (         )
    );

    uisetvbuf u_uisetvbuf (
        .ui_clk(fdma_clk ),
        .bufn_i(W_sync_cnt),
        .bufn_o(rbuf_next)
    );

    /* CVP修(撕裂根因): R_buf 原为 uisetvbuf 组合透传, W_sync_cnt 每逢写帧起始
     * (30fps 自由跑)即变化, 读地址在显示扫描中途当场跳到新缓冲 —— 新旧两帧
     * 在同一场内拼接 = 撕裂, 跳变行位置随 30fps 与 60Hz 两个自由时钟的相位
     * 滑动而漂移。修复: 切换锁存到显示场头(vid_vs), 同帧内不再变化;
     * 相位拍打最多造成同缓冲重复显示一场(静止画面不可见)。 */
    reg [7:0] rbuf_m = 8'd2;
    always @(posedge pclkx1) rbuf_m <= rbuf_next;
    always @(posedge pclkx1) begin
        if (!hdmi_pll_lock)
            R_buf <= 8'd2;
        else if (vid_vs)
            R_buf <= rbuf_m;
    end

    app_fdma u_app_fdma (
        .fdma_clk        (fdma_clk        ),
        .fdma_rstn       (fdma_rstn       ),
        .fdma_waddr      (fdma_waddr[23:0]),
        .fdma_wareq      (fdma_wareq      ),
        .fdma_wsize      (fdma_wsize      ),
        .fdma_wbusy      (fdma_wbusy      ),
        .fdma_wdata      (fdma_wdata      ),
        .fdma_wvalid     (fdma_wvalid     ),
        .fdma_raddr      (fdma_raddr[23:0]),
        .fdma_rareq      (fdma_rareq      ),
        .fdma_rsize      (fdma_rsize      ),
        .fdma_rbusy      (fdma_rbusy      ),
        .fdma_rdata      (fdma_rdata      ),
        .fdma_rvalid     (fdma_rvalid     ),
        .sdr_init_done   (sdr_init_done   ),
        .sdr_init_ref_vld(sdr_init_ref_vld),
        .app_wr_en       (app_wr_en       ),
        .app_wr_addr     (app_wr_addr     ),
        .app_wr_dm       (app_wr_dm       ),
        .app_wr_din      (app_wr_din      ),
        .app_rd_en       (app_rd_en       ),
        .app_rd_addr     (app_rd_addr     ),
        .sdr_rd_en       (sdr_rd_en       ),
        .sdr_rd_dout     (sdr_rd_dout     ),
        .sdr_busy        (sdr_busy        )
    );

    /* DDR1 控制器 + 合封 DDR (引脚由硬宏固定, 无需约束) */
    wire        ddr_CLK, ddr_CLKN, ddr_CKE, ddr_CS_N, ddr_RAS_N, ddr_CAS_N, ddr_WE_N;
    wire [11:0] ddr_ADDR;
    wire [1:0]  ddr_BA, ddr_DM;
    wire [15:0] ddr_DQ;
    wire [1:0]  ddr_DQS;

    ddr1_as_ram #(
        .self_refresh_open(1'b0)
    ) u_ddr_ctrl (
        .Clk0            (ddr_clk0       ),
        .Clk90           (ddr_clk90      ),
        .Clk180          (ddr_clk180     ),
        .Rst             (~ddr_pll_lock  ),
        .Sdr_init_done   (sdr_init_done  ),
        .Sdr_init_ref_vld(sdr_init_ref_vld),
        .Sdr_busy        (sdr_busy       ),
        .App_ref_req     (1'b0           ),
        .App_wr_en       (app_wr_en      ),
        .App_wr_addr     (app_wr_addr    ),
        .App_wr_dm       (app_wr_dm      ),
        .App_wr_din      (app_wr_din     ),
        .App_rd_en       (app_rd_en      ),
        .App_rd_addr     (app_rd_addr    ),
        .Sdr_rd_en       (sdr_rd_en      ),
        .Sdr_rd_dout     (sdr_rd_dout    ),
        .CLK             (ddr_CLK        ),
        .CLKN            (ddr_CLKN       ),
        .CKE             (ddr_CKE        ),
        .CS_N            (ddr_CS_N       ),
        .RAS_N           (ddr_RAS_N      ),
        .CAS_N           (ddr_CAS_N      ),
        .WE_N            (ddr_WE_N       ),
        .BA              (ddr_BA         ),
        .ADDR            (ddr_ADDR       ),
        .DM              (ddr_DM         ),
        .DQ              (ddr_DQ         ),
        .DQS             (ddr_DQS        )
    );

    EG_PHY_DDR_8M_16 u_ddr_sdram (
        .clk  (ddr_CLK  ),
        .clk_n(ddr_CLKN ),
        .ras_n(ddr_RAS_N),
        .cas_n(ddr_CAS_N),
        .we_n (ddr_WE_N ),
        .cs_n (ddr_CS_N ),
        .addr (ddr_ADDR ),
        .ba   (ddr_BA   ),
        .dq   (ddr_DQ   ),
        .ldqs (ddr_DQS[0]),
        .udqs (ddr_DQS[1]),
        .ldm  (ddr_DM[0]),
        .udm  (ddr_DM[1]),
        .cke  (ddr_CKE  )
    );

    /* ================= HDMI 输出 (例程23 时序 + 例程25 RGB 对齐) ================= */
    /* 注: vid_vs/vid_hs/vid_de 声明已提前至模块前部(uidbuf 例化先使用) */
    reg  vid_de_r;
    reg  [7:0] rgb_r, rgb_g, rgb_b;
    wire vid_rst = hdmi_pll_lock;

    /* 像素与 DE 同拍打一寄存器送 uihdmitx (uidbuf 32bit 通路, 像素在 [23:0]) */
    /* ---- 内置彩条发生器(GEN_TESTPAT=1): 8 竖条 SMPTE 风格, 由 uivtc 时序驱动 ---- */
    reg [10:0] r_tpx;      // 行内像素 0..1279
    reg [9:0]  r_tpy;      // 帧内行   0..719
    always @(posedge pclkx1) begin
        if (!vid_de) r_tpx <= 11'd0;
        else         r_tpx <= (r_tpx == 11'd1279) ? 11'd0 : r_tpx + 11'd1;
    end
    always @(posedge pclkx1) begin
        if (vid_vs)      r_tpy <= 10'd0;
        else if (vid_de && r_tpx == 11'd1279)
                         r_tpy <= (r_tpy == 10'd719) ? 10'd0 : r_tpy + 10'd1;
    end
    wire [3:0] w_bar = (r_tpx < 11'd160)  ? 4'd0 :
                       (r_tpx < 11'd320)  ? 4'd1 :
                       (r_tpx < 11'd480)  ? 4'd2 :
                       (r_tpx < 11'd640)  ? 4'd3 :
                       (r_tpx < 11'd800)  ? 4'd4 :
                       (r_tpx < 11'd960)  ? 4'd5 :
                       (r_tpx < 11'd1120) ? 4'd6 : 4'd7;
    reg [23:0] w_bar_rgb;
    always @* begin
        case (w_bar)
            4'd0: w_bar_rgb = 24'hFFFFFF;   // 白
            4'd1: w_bar_rgb = 24'hFFFF00;   // 黄
            4'd2: w_bar_rgb = 24'h00FFFF;   // 青
            4'd3: w_bar_rgb = 24'h00FF00;   // 绿
            4'd4: w_bar_rgb = 24'hFF00FF;   // 品红
            4'd5: w_bar_rgb = 24'hFF0000;   // 红
            4'd6: w_bar_rgb = 24'h0000FF;   // 蓝
            default: w_bar_rgb = 24'h000000; // 黑
        endcase
    end

    /* CVP: 右上角安路 logo OSD 叠加(uidbuf 读出口与 RGB 寄存之间) */
    wire [23:0] osd_rgb;
    wire        osd_de;

    osd_anlogic_logo #(
        .IMG_WIDTH(1280), .LOGO_W(160), .LOGO_H(160),
        .X_POS(1096), .Y_POS(24)
    ) u_osd_logo (
        .I_clk  (pclkx1),
        .I_rst_n(vid_rst),
        .I_vs   (vid_vs),
        .I_de   (vid_de),
        .I_rgb  (R_data[23:0]),
        .O_rgb  (osd_rgb),
        .O_de   (osd_de)
    );

    always @(posedge pclkx1) begin
        vid_de_r <= osd_de;
        if (osd_de) begin
            rgb_r <= GEN_TESTPAT ? w_bar_rgb[23:16] : osd_rgb[23:16];
            rgb_g <= GEN_TESTPAT ? w_bar_rgb[15:8]  : osd_rgb[15:8];
            rgb_b <= GEN_TESTPAT ? w_bar_rgb[7:0]   : osd_rgb[7:0];
        end
    end

    uivtc #(
        .H_ActiveSize(1280          ),
        .H_SyncStart (1280+88       ),
        .H_SyncEnd   (1280+88+44    ),
        .H_FrameSize (1280+88+44+239),
        .V_ActiveSize(720           ),
        .V_SyncStart (720+4         ),
        .V_SyncEnd   (720+4+5       ),
        .V_FrameSize (720+4+5+28    )
    ) u_uivtc (
        .I_vtc_rstn(vid_rst ),
        .I_vtc_clk (pclkx1  ),
        .O_vtc_vs  (vid_vs  ),
        .O_vtc_hs  (vid_hs  ),
        .O_vtc_de  (vid_de  )
    );

    uihdmitx #(
        .FAMILY("EG4")
    ) u_uihdmitx (
        .RSTn_i   (vid_rst      ),
        .HS_i     (vid_hs       ),
        .VS_i     (vid_vs       ),
        .DE_i     (vid_de_r     ),
        .RGB_i    ({rgb_r, rgb_g, rgb_b}),
        .PCLKX1_i (pclkx1       ),
        .PCLKX5_i (pclkx5       ),
        .HDMI_CLK_P(O_HDMI_CLK_P),
        .HDMI_TX_P (O_HDMI_TX_P )
    );

    /* ================= 心跳灯 + 四点夹逼 LED =================
     * LED0(P91)  心跳 ~1.5Hz
     * LED1(P104) = rx_valid 字节计数 bit[24]     CDC 出口(=MAC 入口)
     * LED2(P109) = w_crc_bad 帧计数 bit[10]      MAC 层 CRC 失败帧(闪=字节流中后部坏)
     * LED3(P112) = udp_rx_valid 字节计数 bit[24] UDP 出口
     * 判读: 1不闪=CDC 输出断; 1闪2不闪=MAC 丢(SFD/CRC, 若 crc_bad 在涨=CRC 错);
     *       2闪3不闪=IP/UDP 层丢; 全闪=协议栈通(查重组器) */
    reg [23:0] r_led_cnt;
    always @(posedge I_sys_clk) r_led_cnt <= r_led_cnt + 24'd1;

    reg [24:0] r_cdc_cnt;
    always @(posedge clk_125 or posedge stack_reset_125) begin
        if (stack_reset_125) r_cdc_cnt <= 25'd0;
        else                 r_cdc_cnt <= r_cdc_cnt + rx_valid;
    end

    reg [24:0] r_udpbyte_cnt;
    always @(posedge clk_125 or posedge stack_reset_125) begin
        if (stack_reset_125) r_udpbyte_cnt <= 25'd0;
        else                 r_udpbyte_cnt <= r_udpbyte_cnt + udp_rx_valid;
    end

    /* CVP: 第二阶段读数 —— LED2 = 重组器完成帧计数 bit3(闪=在完整出帧)
     *                     LED3 = FDMA 写 DDR 活动计数(闪=写侧在往 DDR 打数据)
     * 判读: 2闪3闪 = 重组器/FDMA 都活, 查 DDR 内容与读侧;
     *       2闪3灭 = uidbuf/FDMA 写侧死; 2灭 = 重组器没在完整出帧(丢包仍在) */
    reg [24:0] r_fdma_cnt;
    always @(posedge fdma_clk) begin
        if (!fdma_rstn) r_fdma_cnt <= 25'd0;
        else            r_fdma_cnt <= r_fdma_cnt + fdma_wvalid;
    end
    /* CVP: 诊断期读数 —— LED3 = crc_ok 闪(好帧在过 MAC) / LED2 = crc_bad 闪(坏帧)
     * 判读: 3闪2灭 = CRC 通过, 问题在 IP/UDP/重组器; 2闪3灭 = 采样相位又错(重扫 CPHASE);
     *       全灭但 LED1 闪 = MAC 地址/类型过滤丢帧(查 DA/TYPE) */
    assign O_led = { w_crc_ok[10],        // LED3: CRC 通过帧计数(闪=好帧在流过)
                     w_crc_bad[10],       // LED2: CRC 失败帧计数(闪=坏帧, 采样相位问题)
                     r_cdc_cnt[24],       // LED1
                     r_led_cnt[23] };     // LED0 心跳

endmodule
