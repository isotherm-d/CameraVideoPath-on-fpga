/*
 * ============================================================================
 * cvp_eth_dbg —— 以太网视频调试通路（自研，MLKPAI-F02 无 HDMI 的临时方案）
 *
 * 数据流(v5 架构)：
 *   像素流(i_clk_pix, 每拍 1 个 RGB888) → 24bit 像素跨域 FIFO
 *   → [GMII 125M 域] 3 拍/像素字节展开 → 8bit 弹性 FIFO(同域)
 *   → GMAC(自插 6B 应用头) → RGMII → 底板 ETHA(YT8531) → PC
 *
 * v5 变更(根因: v4 把 3 倍字节展开放在像素时钟域):
 *   S_csi_rx_clk 实测约 40.2MHz(=321.6Mbps/lane÷8), 每行 1024 像素需
 *   3072 个字节拍(76.4us) > 行周期 44.4us —— 物理不可能实时, pack FIFO
 *   长期满静默丢像素 → 帧字节数凑满但内容跨 ~4.4 个传感器帧(撕裂、~4.4fps)。
 *   修复: 跨域点前移为"整像素"(24bit FIFO), 字节展开搬到 GMII 125M 域
 *   (3 拍/像素 = 41.7M 字节/s 能力 > 需求 36.9M), 帧计数/信用/跳帧一并
 *   搬域, 与 MAC 同域后信用无需跨域同步(保留 Gray 编码形式以复用 MAC)。
 *
 * UDP 协议（大端，应用头 6 字节 + 固定 1440B 像素数据，见 cvp_gmii_mac_tx）：
 *   byte0 frame_seq | byte1 fmt=0x01 | byte2..5 offset（帧内字节偏移）
 *   PC 按偏移写入帧缓冲，缺包留黑洞。
 *
 * 注意：IMG_W*IMG_H*3 必须能被 DATA_BYTES 整除。
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
    /* ---- 像素输入（CSI byte 时钟域, 每拍 1 像素） ---- */
    input  wire        i_clk_pix,
    input  wire        i_rst_pix_n,
    input  wire        i_valid,
    input  wire [23:0] i_rgb,            // {R,G,B}

    /* ---- 100MHz（MDIO 域） ---- */
    input  wire        i_clk_100m,
    input  wire        i_rst_100m_n,

    /* ---- 125MHz GMII 域 ---- */
    input  wire        i_clk_gmii,
    input  wire        i_rst_gmii_n,

    /* ---- RGMII（ETHA） ---- */
    input  wire        i_txd_swap,
    input  wire [15:0] i_dbg_flags,
    input  wire [15:0] i_scan_word,
    output wire        o_scan_rotate,
    output wire [3:0]  o_rgmii_txd,
    output wire        o_rgmii_tx_ctl,
    output wire        o_rgmii_txc,

    /* ---- MDIO ---- */
    output wire        o_eth_mdc,
    output wire        o_eth_mdio_o,
    output wire        o_eth_mdio_oe,
    input  wire        i_eth_mdio_i,

    /* ---- 观测（高有效语义，LED 低有效在顶层取反） ---- */
    output wire        o_link,
    output wire        o_act,
    output wire        o_ext_dly
);

    localparam integer PKTS_PER_FRAME = IMG_W * IMG_H * 3 / DATA_BYTES;
    localparam integer FIFO_AW        = 13;   // 8bit x 8192 字节弹性缓冲(GMII 域)
    localparam integer PXF_AW         = 11;   // 24bit x 2048 像素跨域 FIFO(≥2 行)

    // 帧内字节计数终点(每有效拍写 1 字节, 一帧 = IMG_W*IMG_H*3 字节)
    localparam [20:0] PX_LAST = IMG_W * IMG_H * 3 - 1;

    /* ---------------- 测试图案发生器（GEN_TESTPAT=1 时替代上游像素流） ----------------
     * 自由时序：IMG_W 有效 + 100 消隐拍；8 条等宽竖彩条。每拍 1 像素。 */
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

    /* ---------------- 24bit 像素跨域 FIFO（像素域 → GMII 域） ---------------- */
    wire        w_pxf_rd, w_pxf_valid, w_pxf_empty;
    wire [23:0] w_pxf_data;

    cvp_async_fifo #(
        .DATA_WIDTH (24),
        .ADDR_WIDTH (PXF_AW)
    ) u_px_fifo (
        .wr_clk   (i_clk_pix),
        .wr_rst_n (i_rst_pix_n),
        .wr_en    (w_pix_valid),          // 满则丢(上游 pack 已保证平均速率可跟进)
        .wr_data  (w_pix_rgb),
        .wr_full  (),
        .wr_level (),
        .wr_flush (1'b0),
        .rd_clk   (i_clk_gmii),
        .rd_rst_n (i_rst_gmii_n),
        .rd_en    (w_pxf_rd),
        .rd_data  (w_pxf_data),
        .rd_valid (w_pxf_valid),
        .rd_empty (w_pxf_empty),
        .rd_flush (1'b0)
    );

    /* ---------------- GMII 域：3 拍/像素字节展开 + 帧计数 + 信用 + 跳帧 ----------------
     * 流水: bsel=0 写R(装载拍用 rd 数据) → bsel=1 写G(发 rd_en 预取) →
     *       bsel=2 写B(锁存下一像素) → 无气泡 3 拍/像素。
     * 帧边界: r_px 数满 IMG_W*IMG_H*3 字节; 帧尾为下一帧判定 r_capture(水位)。 */
    reg  [20:0] r_px;        // 帧内字节计数(每展开拍 +1, 与原版语义一致: 不看 capture)
    reg  [1:0]  r_bsel;      // 当前字节 0=R 1=G 2=B
    reg  [23:0] r_pix;       // 正在展开的像素
    reg         r_run;       // 展开中
    reg  [10:0] r_burst;     // 块内字节计数 0..DATA_BYTES-1
    reg  [6:0]  r_credit_bin;// 已生产整块数(mod 128)
    reg  [3:0]  r_skip;
    reg         r_capture;   // 当前帧是否写入(上一帧尾决定)

    wire        w_bf_full;
    wire [FIFO_AW:0] w_bf_level;
    wire        w_rd_en, w_rd_valid, w_rd_empty;   // 8bit FIFO 读侧(由 MAC 驱动)
    wire [7:0]  w_rd_data;

    // 取新像素: 装载态常取; 展开中在 bsel=1 拍预取(bsel=2 拍锁存)
    assign w_pxf_rd = (!w_pxf_empty) && ( (!r_run) || (r_bsel == 2'd1) );

    // 本拍有字节活动: 展开中, 或装载拍(数据已到)
    wire w_load    = (!r_run) && w_pxf_valid;          // 装载拍: 该拍即写 byte0
    wire w_adv     = r_run || w_load;
    // 当前像素: 装载拍用 FIFO 读出数据, 其余拍用锁存值
    wire [23:0] w_cur = w_load ? w_pxf_data : r_pix;
    wire [7:0]  w_byte = (r_bsel == 2'd0) ? w_cur[23:16] :
                         (r_bsel == 2'd1) ? w_cur[15:8]  :
                                            w_cur[7:0];

    wire w_frame_last = (r_px == PX_LAST);
    wire w_write      = w_adv && r_capture && !w_bf_full;
    wire w_chunk_done = w_write && (r_burst == DATA_BYTES - 1);

    /* bin→gray */
    function [6:0] bin2gray;
        input [6:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction
    wire [6:0] r_credit_gray = bin2gray(r_credit_bin);   // 同域, MAC 内同步链无害

    cvp_async_fifo #(
        .DATA_WIDTH (8),
        .ADDR_WIDTH (FIFO_AW)
    ) u_fifo (
        .wr_clk   (i_clk_gmii),          // v5: 8bit FIFO 变为 GMII 同域弹性缓冲
        .wr_rst_n (i_rst_gmii_n),
        .wr_en    (w_write),
        .wr_data  (w_byte),
        .wr_full  (w_bf_full),
        .wr_level (w_bf_level),
        .wr_flush (1'b0),
        .rd_clk   (i_clk_gmii),
        .rd_rst_n (i_rst_gmii_n),
        .rd_en    (w_rd_en),
        .rd_data  (w_rd_data),
        .rd_valid (w_rd_valid),
        .rd_empty (w_rd_empty),
        .rd_flush (1'b0)
    );

    always @(posedge i_clk_gmii or negedge i_rst_gmii_n) begin
        if (!i_rst_gmii_n) begin
            r_px          <= 21'd0;
            r_bsel        <= 2'd0;
            r_pix         <= 24'd0;
            r_run         <= 1'b0;
            r_burst       <= 11'd0;
            r_credit_bin  <= 7'd0;
            r_skip        <= 4'd0;
            r_capture     <= 1'b0;
        end else if (w_adv) begin
            /* 字节相位推进: 每展开拍轮转(含帧尾拍; 帧字节预算是 3 的倍数,
             * 帧尾恰好停在 B(bsel=2), 推进到 0=下一像素 R, 跨帧天然对齐,
             * 不清 r_bsel/r_run —— 否则帧边界丢 1 个已预取像素致撕裂) */
            r_bsel <= (r_bsel == 2'd2) ? 2'd0 : r_bsel + 2'd1;

            /* 像素锁存/展开状态 */
            if (w_load) begin
                r_pix <= w_pxf_data;               // 装载新像素
                r_run <= 1'b1;
            end else if (r_bsel == 2'd2) begin
                if (w_pxf_valid)
                    r_pix <= w_pxf_data;           // 无气泡切换下一像素
                else
                    r_run <= 1'b0;                 // 供数中断, 回装载态
            end

            /* 帧内字节计数(不看 capture, 与原版语义一致) */
            if (w_frame_last) begin
                r_px      <= 21'd0;
                r_skip    <= (r_skip == FRAME_SKIP - 1) ? 4'd0 : r_skip + 4'd1;
                r_capture <= (r_skip == 4'd0) &&
                             (w_bf_level < (1 << FIFO_AW >> 1));
            end else begin
                r_px <= r_px + 21'd1;
            end

            /* 整块信用: 每写满 DATA_BYTES 字节记一次 */
            if (w_chunk_done) begin
                r_burst      <= 11'd0;
                r_credit_bin <= r_credit_bin + 7'd1;
            end else if (w_write) begin
                r_burst <= r_burst + 11'd1;
            end
        end
    end

    /* ---------------- GMII 域：MAC（应用头由 MAC 自插） ---------------- */
    wire        w_tx_pkt;
    wire        w_hb_pkt;
    reg  [15:0] r_flags_s1, r_flags_s2;
    reg  [15:0] r_scan_s1, r_scan_s2;
    reg  [2:0]  r_scan_page;

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
