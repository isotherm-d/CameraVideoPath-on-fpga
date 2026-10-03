/*
 * ============================================================================
 * cvp_eth_dbg —— 以太网视频调试通路（自研，MLKPAI-F02 无 HDMI 的临时方案）
 *
 * 数据流：
 *   显示读出像素流(OSD后, 75M) → 跳帧(N 帧发 1 帧) → 8bit 异步 FIFO（纯字节）
 *   → GMAC(125M，自插 6B 应用头) → RGMII → 底板 ETHA(YT8531) → PC
 *
 * UDP 协议（大端，应用头 6 字节 + 固定 1440B 像素数据，见 cvp_gmii_mac_tx）：
 *   byte0 frame_seq | byte1 fmt=0x01 | byte2..5 offset（帧内字节偏移）
 *   一帧 = 1280*720*3/1440 = 1920 包，PC 按偏移写入帧缓冲，缺包留黑洞。
 *
 * 像素域只做三件事：按 i_valid 把 RGB 三字节原序写入 FIFO（零丢失、零插入，
 * 字节流天然连续）、每写满 1440B 记一次 Gray 信用（MAC 以此保证整包起发）、
 * 按帧计数跳帧。包头由 MAC 域插入，像素流里没有插入开销。
 *
 * 带宽：720p60 RGB888 全速 1.33Gbps 超千兆，默认 FRAME_SKIP=3（20fps，
 * ~450Mbps 线速率）；链路稳定后可改 2（30fps，~750Mbps，接近极限）。
 *
 * 时钟：像素 75MHz 写 FIFO；GMII 125MHz（cvp_top 内由 375MHz 串行钟 3 分频）；
 * MDIO 100MHz。复位由 cvp_top 按域同步后接入。
 *
 * 注意：IMG_W*IMG_H*3 必须能被 DATA_BYTES 整除（2764800/1440=1920 ✓）。
 * ============================================================================
 */
module cvp_eth_dbg #(
    parameter integer IMG_W        = 1280,
    parameter integer IMG_H        = 720,
    parameter integer FRAME_SKIP   = 3,      // 每 N 帧发 1 帧
    parameter integer DATA_BYTES   = 1440,   // 每包像素字节数（须被 3 整除）
    parameter integer GEN_TESTPAT  = 1,      // 1=内置彩条发生器（不依赖上游 valid）
    parameter [47:0]  MAC_DST      = 48'hFF_FF_FF_FF_FF_FF,
    parameter [47:0]  MAC_SRC      = 48'h02_1A_2B_3C_4D_5E,
    parameter [31:0]  IP_SRC       = 32'hC0_A8_01_42,
    parameter [31:0]  IP_DST       = 32'hC0_A8_01_64,
    parameter [15:0]  UDP_SPORT    = 16'd6000,
    parameter [15:0]  UDP_DPORT    = 16'd6000,
    parameter [4:0]   PHY_ADDR     = 5'd1
) (
    /* ---- 像素输入（75MHz 显示域） ---- */
    input  wire        i_clk_pix,
    input  wire        i_rst_pix_n,
    input  wire        i_valid,          // OSD 输出有效像素
    input  wire [23:0] i_rgb,            // {R,G,B}

    /* ---- 100MHz（MDIO 域） ---- */
    input  wire        i_clk_100m,
    input  wire        i_rst_100m_n,

    /* ---- 125MHz GMII 域 ---- */
    input  wire        i_clk_gmii,
    input  wire        i_rst_gmii_n,

    /* ---- RGMII（ETHA） ---- */
    input  wire        i_txd_swap,       // SW2：ODDR d0/d1 端口交换（硅片语义排查）
    input  wire [15:0] i_dbg_flags,      // 链路状态标志（100M 域准静态电平，心跳包载荷）
    input  wire [15:0] i_scan_word,      // I2C 扫描位图旋转窗（随 o_scan_rotate 推进）
    output wire        o_scan_rotate,    // 心跳包脉冲（顶层借此旋转扫描窗）
    output wire [3:0]  o_rgmii_txd,
    output wire        o_rgmii_tx_ctl,
    output wire        o_rgmii_txc,

    /* ---- MDIO ---- */
    output wire        o_eth_mdc,
    output wire        o_eth_mdio_o,
    output wire        o_eth_mdio_oe,
    input  wire        i_eth_mdio_i,

    /* ---- 观测（高有效语义，LED 低有效在顶层取反） ---- */
    output wire        o_link,           // PHY 链路建立
    output wire        o_act,            // 发包闪烁
    output wire        o_ext_dly         // EXT_0xA001.bit8（PHY RX 2ns 延时状态）→ LED3
);

    localparam integer PKTS_PER_FRAME = IMG_W * IMG_H * 3 / DATA_BYTES; // 1920
    localparam integer FIFO_AW        = 13;   // 8192 x 8bit ≈ 5.6 包
    localparam [20:0] PX_LAST = IMG_W * IMG_H - 1;

    /* ---------------- 测试图案发生器（GEN_TESTPAT=1 时替代上游像素流） ----------------
     * 720p 自由时序：1280 有效 + 100 消隐拍；8 条 160 像素竖彩条。
     * 用途：相机链路没跑通时验证 网口→PC 全链路；GEN_TESTPAT=0 用真实像素流。 */
    reg [10:0] r_tpx;
    reg [9:0]  r_tpy;
    wire       w_gen_valid = (r_tpx < IMG_W);
    wire [3:0] w_bar = (r_tpx < 11'd160)  ? 4'd0 :
                       (r_tpx < 11'd320)  ? 4'd1 :
                       (r_tpx < 11'd480)  ? 4'd2 :
                       (r_tpx < 11'd640)  ? 4'd3 :
                       (r_tpx < 11'd800)  ? 4'd4 :
                       (r_tpx < 11'd960)  ? 4'd5 :
                       (r_tpx < 11'd1120) ? 4'd6 : 4'd7;
    reg  [23:0] w_gen_rgb;
    always @* begin
        case (w_bar)
            4'd0: w_gen_rgb = 24'hFFFFFF;
            4'd1: w_gen_rgb = 24'hFFFF00;
            4'd2: w_gen_rgb = 24'h00FFFF;
            4'd3: w_gen_rgb = 24'h00FF00;
            4'd4: w_gen_rgb = 24'hFF00FF;
            4'd5: w_gen_rgb = 24'hFF0000;
            4'd6: w_gen_rgb = 24'h0000FF;
            default: w_gen_rgb = 24'h202020;
        endcase
    end

    always @(posedge i_clk_pix or negedge i_rst_pix_n) begin
        if (!i_rst_pix_n) begin
            r_tpx <= 11'd0;
            r_tpy <= 10'd0;
        end else if (GEN_TESTPAT) begin
            if (r_tpx == IMG_W + 99) begin
                r_tpx <= 11'd0;
                r_tpy <= (r_tpy == IMG_H - 1) ? 10'd0 : r_tpy + 10'd1;
            end else begin
                r_tpx <= r_tpx + 11'd1;
            end
        end
    end

    wire        w_pix_valid = (GEN_TESTPAT != 0) ? (w_gen_valid && GEN_TESTPAT) : i_valid;
    wire [23:0] w_pix_rgb   = (GEN_TESTPAT != 0) ? w_gen_rgb : i_rgb;

    /* ---------------- FIFO ---------------- */
    wire             w_wr_full;
    wire [FIFO_AW:0] w_wr_level;
    wire             w_rd_en, w_rd_valid, w_rd_empty;
    wire [7:0]       w_rd_data;

    /* ---------------- 像素域：纯字节写入 + 信用 + 跳帧 ---------------- */
    reg [20:0] r_px;       // 帧内像素计数 0..PX_LAST
    reg [1:0]  r_bsel;     // 像素字节序 0=R 1=G 2=B（帧边界对齐像素0）
    reg [10:0] r_burst;    // 块内字节计数 0..DATA_BYTES-1（须容纳 1439）
    reg [6:0]  r_credit_bin, r_credit_gray;
    reg [3:0]  r_skip;
    reg        r_capture;  // 当前帧是否写入（上一帧结束时决定）

    wire w_frame_last = (r_px == PX_LAST);
    wire w_write      = w_pix_valid && r_capture && !w_wr_full;
    wire w_chunk_done = w_write && (r_burst == DATA_BYTES - 1);

    wire [7:0] w_byte = (r_bsel == 2'd0) ? w_pix_rgb[23:16] :
                        (r_bsel == 2'd1) ? w_pix_rgb[15:8]  :
                                           w_pix_rgb[7:0];

    cvp_async_fifo #(
        .DATA_WIDTH (8),
        .ADDR_WIDTH (FIFO_AW)
    ) u_fifo (
        .wr_clk   (i_clk_pix),
        .wr_rst_n (i_rst_pix_n),
        .wr_en    (w_write),
        .wr_data  (w_byte),
        .wr_full  (w_wr_full),
        .wr_level (w_wr_level),
        .wr_flush (1'b0),
        .rd_clk   (i_clk_gmii),
        .rd_rst_n (i_rst_gmii_n),
        .rd_en    (w_rd_en),
        .rd_data  (w_rd_data),
        .rd_valid (w_rd_valid),
        .rd_empty (w_rd_empty),
        .rd_flush (1'b0)
    );

    /* bin→gray（每次 +1 的路径只有最低变化，直接整字转换） */
    function [6:0] bin2gray;
        input [6:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    always @(posedge i_clk_pix or negedge i_rst_pix_n) begin
        if (!i_rst_pix_n) begin
            r_px          <= 21'd0;
            r_bsel        <= 2'd0;
            r_burst       <= 11'd0;
            r_credit_bin  <= 7'd0;
            r_credit_gray <= 7'd0;
            r_skip        <= 4'd0;
            r_capture     <= 1'b0;
        end else if (w_pix_valid) begin
            /* 帧内计数 */
            if (w_frame_last) begin
                r_px      <= 21'd0;
                r_bsel    <= 2'd0;
                /* 帧结束：为下一帧做决定。水位门槛保证整帧写入期间
                 * FIFO 不溢出（消费者 125M 比生产者快 2.6 倍）。 */
                r_skip    <= (r_skip == FRAME_SKIP - 1) ? 4'd0 : r_skip + 4'd1;
                r_capture <= (r_skip == 4'd0) &&
                             (w_wr_level < (1 << FIFO_AW >> 1));
            end else begin
                r_px   <= r_px + 21'd1;
                r_bsel <= (r_bsel == 2'd2) ? 2'd0 : r_bsel + 2'd1;
            end

            /* 整块信用：每写满 DATA_BYTES 字节记一次 */
            if (w_chunk_done) begin
                r_burst       <= 11'd0;
                r_credit_bin  <= r_credit_bin + 7'd1;
                r_credit_gray <= bin2gray(r_credit_bin + 7'd1);
            end else if (w_write) begin
                r_burst <= r_burst + 11'd1;
            end
        end
    end

    /* ---------------- GMII 域：MAC（应用头由 MAC 自插） ---------------- */
    wire w_tx_pkt;
    wire w_hb_pkt;                          // 心跳包脉冲（MAC 发出）
    reg [15:0] r_flags_s1, r_flags_s2;      // 标志束同步进 GMII 域（准静态电平）
    reg [15:0] r_scan_s1, r_scan_s2;        // 扫描旋转窗同步
    reg [2:0]  r_scan_page;                 // 心跳页计数（与 MAC 内 r_hb_seq 同步增长）

    always @(posedge i_clk_gmii or negedge i_rst_gmii_n) begin
        if (!i_rst_gmii_n) begin
            r_flags_s1 <= 16'h0000;
            r_flags_s2 <= 16'h0000;
            r_scan_s1  <= 16'h0000;
            r_scan_s2  <= 16'h0000;
            r_scan_page<= 3'd0;
        end else begin
            r_flags_s1 <= i_dbg_flags;
            r_flags_s2 <= r_flags_s1;
            r_scan_s1  <= i_scan_word;
            r_scan_s2  <= r_scan_s1;
            if (w_hb_pkt) r_scan_page <= r_scan_page + 3'd1;
        end
    end

    /* 顶层旋转窗按本域页计数选择（组合，仅心跳载荷使用） */
    reg [15:0] r_scan_word_g;
    always @* begin
        case (r_scan_page)
            3'd0: r_scan_word_g = r_scan_s2;
            default: r_scan_word_g = r_scan_s2;   // 页选择由顶层旋转完成，此处直通
        endcase
    end

    cvp_gmii_mac_tx #(
        .DATA_BYTES     (DATA_BYTES),
        .PKTS_PER_FRAME (PKTS_PER_FRAME),
        .MAC_DST        (MAC_DST),
        .MAC_SRC        (MAC_SRC),
        .IP_SRC         (IP_SRC),
        .IP_DST         (IP_DST),
        .UDP_SPORT      (UDP_SPORT),
        .UDP_DPORT      (UDP_DPORT)
    ) u_mac (
        .i_clk          (i_clk_gmii),
        .i_rst          (~i_rst_gmii_n),
        .i_txd_swap     (i_txd_swap),
        .i_dbg_flags    (r_flags_s2),
        .i_scan_word    (r_scan_word_g),
        .o_hb_pkt       (w_hb_pkt),
        .i_credit_gray  (r_credit_gray),
        .o_rd_en        (w_rd_en),
        .i_rd_empty     (w_rd_empty),
        .i_rd_valid     (w_rd_valid),
        .i_rd_data      (w_rd_data),
        .o_rgmii_txd    (o_rgmii_txd),
        .o_rgmii_tx_ctl (o_rgmii_tx_ctl),
        .o_rgmii_txc    (o_rgmii_txc),
        .o_tx_pkt       (w_tx_pkt)
    );

    /* ---------------- MDIO（100M 域）+ 观测 ---------------- */
    wire w_link;
    wire [15:0] w_ext_a001;
    reg  [1:0] r_mdio_sync;
    reg        r_act_tgl;

    always @(posedge i_clk_100m or negedge i_rst_100m_n) begin
        if (!i_rst_100m_n) r_mdio_sync <= 2'b11;
        else               r_mdio_sync <= {r_mdio_sync[0], i_eth_mdio_i};
    end

    cvp_mdio_ro #(
        .CLK_DIV  (20),
        .PHY_ADDR (PHY_ADDR)
    ) u_mdio (
        .i_clk     (i_clk_100m),
        .i_rst_n   (i_rst_100m_n),
        .o_mdc     (o_eth_mdc),
        .o_mdio_o  (o_eth_mdio_o),
        .o_mdio_oe (o_eth_mdio_oe),
        .i_mdio_i  (r_mdio_sync[1]),
        .o_link    (w_link),
        .o_ext_a001(w_ext_a001)
    );

    /* 发包闪烁（链路断也闪，便于区分"没发"和"没链路"） */
    always @(posedge i_clk_gmii or negedge i_rst_gmii_n) begin
        if (!i_rst_gmii_n) r_act_tgl <= 1'b0;
        else if (w_tx_pkt) r_act_tgl <= ~r_act_tgl;
    end

    assign o_link    = w_link;
    assign o_act     = r_act_tgl;
    assign o_ext_dly = w_ext_a001[8];   // Rxc_dly_en 最终状态 → LED3
    assign o_scan_rotate = w_hb_pkt;    // 每个心跳包推进一页扫描窗（顶层 100M 域同步）

endmodule
