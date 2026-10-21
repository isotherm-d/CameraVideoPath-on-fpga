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
    parameter integer ENABLE_STATUS=0,
    parameter integer STATUS_BITS=1024,
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
    /* ---- 像素输入（CSI byte 时钟域, 每拍 4 像素 = 96bit, 与 AWB 观测口一致） ---- */
    input  wire        i_clk_pix,
    input  wire        i_rst_pix_n,
    input  wire        i_valid,          // 96bit 拍有效
    input  wire [95:0] i_rgb,            // {pix0[23:0], pix1, pix2, pix3}
    input wire [31:0] i_frame_id,
    input wire [STATUS_BITS-1:0] i_status_data,input wire i_status_valid,output wire o_status_ready,
    output wire o_frame_tx_done,output wire [31:0] o_frame_tx_id,output wire o_pixel_overflow,
    input  wire        i_tuser,          // 帧头拍标记(与 i_valid 同拍, 单拍脉冲)

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
    localparam integer FRAME_BYTES = IMG_W * IMG_H * 3;
    localparam integer BYTE_COUNT_W = $clog2(FRAME_BYTES);
    localparam [BYTE_COUNT_W-1:0] PX_LAST = FRAME_BYTES - 1;

    /* ---------------- 测试图案发生器（GEN_TESTPAT=1 时替代上游像素流） ----------------
     * 自由时序：每行 IMG_W/4 个 96bit 拍(4像素/拍) + 25 消隐拍；8 条等宽竖彩条。
     * 每拍拼 4 个同列像素([95:72]=像素0 ... [23:0]=像素3), 与 AWB 观测口一致。 */
    reg [10:0] r_tpx;                    // 拍内像素列计数 0..IMG_W-1
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

    // 每 4 个连续列像素拼一拍(列对齐像素序: pix0=最左)
    wire        w_gen_beat_v = w_gen_valid && (r_tpx[1:0] == 2'b11);   // 每4列末拍出
    wire [95:0] w_gen_beat = {w_gen_rgb, w_gen_rgb, w_gen_rgb, w_gen_rgb};
    wire        w_gen_tuser = w_gen_beat_v && (r_tpy == 10'd0) && (r_tpx == 11'd3);

    wire        w_pix_valid = (GEN_TESTPAT != 0) ? w_gen_beat_v : i_valid;
    wire [95:0] w_pix_rgb   = (GEN_TESTPAT != 0) ? w_gen_beat   : i_rgb;
    wire        w_pix_tuser = (GEN_TESTPAT != 0) ? w_gen_tuser  : i_tuser;

    /* ---------------- 97bit 拍跨域 FIFO（像素域 → GMII 域） ----------------
     * bit96 = 帧头标记(带内随数据流走, 跨域零相位误差)。
     * 读侧每 12 拍读 1 次(4像素x3字节展开), 写侧突发 40.2M 拍/s 段,
     * 稳态水位 0~200 波动: 读时 FIFO 几乎常有货, Gray 保守空判决
     * 每行至多触发一次(损失 ~1%), 无需本地预取队列(v8/v9 方案已弃)。 */
    wire        w_pxf_rd, w_pxf_valid, w_pxf_empty;
    wire [128:0] w_pxf_data;
    wire px_full;
    assign o_pixel_overflow=w_pix_valid&&px_full;

    cvp_async_fifo #(
        .DATA_WIDTH (129),
        .ADDR_WIDTH (PXF_AW)
    ) u_px_fifo (
        .wr_clk   (i_clk_pix),
        .wr_rst_n (i_rst_pix_n),
        .wr_en    (w_pix_valid),          // 满则丢(上游平均速率远低于读能力)
        .wr_data  ({i_frame_id,w_pix_tuser, w_pix_rgb}),
        .wr_full  (px_full),
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

    /* ---------------- GMII 域：12 拍/96bit 拍字节展开 + 帧对齐 + 帧计数 + 信用 + 跳帧 ----------------
     * 流水: 每个输入拍(4 像素)展开 12 拍(sel 0..3 像素 x bsel 0..2 字节)。
     * 预取: sel==3&&bsel==1 拍发 rd_en, 数据在 sel==3&&bsel==2 拍到达并锁存,
     * 下一拍无缝切换到新拍的 sel0/bsel0。无气泡 12 拍/输入拍。
     * 帧对齐: 输入 bit96=帧头标记。新拍首字节拍(sel0/bsel0)若标记=1 ->
     * r_px 清 0(本拍即帧 byte0), r_bsel/r_sel 已在切换点天然为 0,
     * 跳帧判定在此拍做。字节计数 PX_LAST 仍作兜底(丢数据时防卡死)。 */
    reg  [BYTE_COUNT_W-1:0] r_px; // Index of the next byte of a real sensor frame.
    reg         r_frame_active;
    reg         r_read_pending;
    reg  [1:0]  r_bsel;      // 当前字节 0=R 1=G 2=B
    reg  [1:0]  r_sel;       // 当前像素 0..3 (像素序 [95:72] 最先)
    reg  [95:0] r_beat;      // 正在展开的 96bit 拍
    reg         r_run;       // 展开中
    reg  [10:0] r_burst;     // 块内字节计数 0..DATA_BYTES-1
    reg  [6:0]  r_credit_bin;// 已生产整块数(mod 128)
    reg  [3:0]  r_skip;
    reg         r_capture;   // 当前帧是否写入(帧头拍决定)

    wire        w_bf_full;
    wire [FIFO_AW:0] w_bf_level;
    wire        w_rd_en, w_rd_valid, w_rd_empty;   // 8bit FIFO 读侧(由 MAC 驱动)
    wire [7:0]  w_rd_data;

    // 取新拍: 装载态常取; 展开中在 (sel==3, bsel==1) 预取
    // One outstanding read; reserve room for the current and prefetched word.
    // Otherwise the idle path can pop a second word while accepting the first.
    assign w_pxf_rd = (!w_pxf_empty) && !r_read_pending && !w_pxf_valid &&
                     (w_bf_level < (1 << FIFO_AW) - 32) &&
                     ((!r_run) || ((r_sel == 2'd3) && (r_bsel == 2'd1)));

    // 本拍有字节活动: 展开中, 或装载拍(FIFO 数据已到)
    wire w_load    = (!r_run) && w_pxf_valid;      // 装载拍: 该拍即写 byte0(sel0/bsel0)
    wire w_adv     = r_run || w_load;
    // 帧头标记: 只在"新拍首字节拍"采样 = 装载拍 或 上一拍刚切换过来的 sel0/bsel0 拍
    // (注意不能在切换拍 sel3/bsel2 采样: 标记恰在该拍锁存, 同拍读到的是陈旧值)
    wire w_beat_first = w_load || (r_run && (r_sel == 2'd0) && (r_bsel == 2'd0));
    // 切换拍锁存的新拍 SOF 标记(下拍 = 新拍首字节拍生效)
    reg  r_sof_pending;
    reg [31:0] beat_frame_id;
    wire w_sof = w_beat_first && (w_load ? w_pxf_data[96] : r_sof_pending);
    wire [95:0] w_cur = w_load ? w_pxf_data[95:0] : r_beat;
    // 字节选择: 像素 r_sel(0=[95:72] 最先) x 字节 r_bsel(0=R)
    wire [6:0]  w_bsh  = (3 - r_sel) * 24 + (2 - r_bsel) * 8;   // 0..88
    wire [7:0]  w_byte = w_cur >> w_bsh;

    wire w_frame_last = r_frame_active && (r_px == PX_LAST);
    // 帧头拍使用"本帧判定值"(跳帧判定在帧头拍即生效), 否则帧头第一字节会因
    // r_capture 尚未更新而被丢 -> 每帧缺 1 字节 -> 全帧错位
    wire w_cap_now    = w_sof ? ((r_skip == 4'd0) &&
                                 (w_bf_level < (1 << FIFO_AW >> 1)))
                              : (r_frame_active && r_capture);
    wire w_write      = w_adv && w_cap_now && !w_bf_full;
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
        .wr_clk   (i_clk_gmii),          // 8bit FIFO 为 GMII 同域弹性缓冲
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
            r_px          <= 0;
            r_frame_active<= 1'b0;
            r_read_pending<= 1'b0;
            r_bsel        <= 2'd0;
            r_sel         <= 2'd0;
            r_beat        <= 96'd0;
            r_run         <= 1'b0;
            r_sof_pending <= 1'b0;
            r_burst       <= 11'd0;
            r_credit_bin  <= 7'd0;
            r_skip        <= 4'd0;
            r_capture     <= 1'b0;
        end else begin
            if (w_pxf_rd) r_read_pending <= 1'b1;
            if (w_pxf_valid) r_read_pending <= 1'b0;
            if (w_adv) begin
            /* 字节相位推进: 12 拍循环(帧尾字节=像素3的B, 帧字节预算为 12 的倍数,
             * 帧尾恰好回到切换点, 跨帧天然对齐; 帧头标记再做强制对齐兜底) */
            if ((r_sel == 2'd3) && (r_bsel == 2'd2)) begin
                r_sel  <= 2'd0;
                r_bsel <= 2'd0;
            end else if (r_bsel == 2'd2) begin
                r_sel  <= r_sel + 2'd1;
                r_bsel <= 2'd0;
            end else begin
                r_bsel <= r_bsel + 2'd1;
            end

            /* 96bit 拍锁存/展开状态 */
            if (w_load) begin
                r_beat        <= w_pxf_data[95:0];beat_frame_id<=w_pxf_data[128:97];   // 装载新拍
                r_sof_pending <= 1'b0;
                r_run         <= 1'b1;
            end else if ((r_sel == 2'd3) && (r_bsel == 2'd2)) begin
                if (w_pxf_valid) begin
                    r_beat        <= w_pxf_data[95:0];beat_frame_id<=w_pxf_data[128:97]; // 无气泡切换下一拍
                    r_sof_pending <= w_pxf_data[96];
                end else begin
                    r_run         <= 1'b0;             // 供数中断, 回装载态
                    r_sof_pending <= 1'b0;
                end
            end

            /* 帧字节计数 + 帧头标记强制对齐(标记优先, 计数兜底) */
            if (w_sof) begin
                r_px      <= 1; // SOF byte zero is written on this clock.
                r_frame_active <= 1'b1;
                r_skip    <= (r_skip == FRAME_SKIP - 1) ? 4'd0 : r_skip + 4'd1;
                r_capture <= (r_skip == 4'd0) &&
                             (w_bf_level < (1 << FIFO_AW >> 1));
            end else if (w_frame_last) begin
                r_px      <= 0;
                r_frame_active <= 1'b0;
                r_capture <= 1'b0; // A byte budget is not permission to invent SOF.
            end else if (r_frame_active) begin
                r_px <= r_px + 1'b1;
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

    wire desc_valid,desc_ready,desc_pop;wire [31:0] desc_id;
    cvp_sync_fifo #(.DW(32),.AW(4)) frame_descriptors(
      .clk(i_clk_gmii),.rst_n(i_rst_gmii_n),
      .i_valid(w_sof&&w_cap_now&&ENABLE_STATUS),
      .i_data(w_load?w_pxf_data[128:97]:beat_frame_id),
      .o_ready(desc_ready),.o_valid(desc_valid),.o_data(desc_id),.i_ready(desc_pop),.o_level());
    wire status_valid,status_pop;wire [STATUS_BITS-1:0] status_data;
    cvp_mailbox #(.DW(STATUS_BITS)) status_bridge(
      .s_clk(i_clk_100m),.s_rst_n(i_rst_100m_n),.s_valid(i_status_valid),.s_data(i_status_data),.s_ready(o_status_ready),
      .m_clk(i_clk_gmii),.m_rst_n(i_rst_gmii_n),.m_valid(status_valid),.m_data(status_data),.m_ready(status_pop));
    cvp_gmii_mac_tx #(
        .ENABLE_STATUS(ENABLE_STATUS),.STATUS_BITS(STATUS_BITS),
        .DATA_BYTES     (DATA_BYTES),
        .PKTS_PER_FRAME (PKTS_PER_FRAME),
        .MAC_DST        (MAC_DST),
        .MAC_SRC        (MAC_SRC),
        .IP_SRC         (IP_SRC),
        .IP_DST         (IP_DST),
        .UDP_SPORT      (UDP_SPORT),
        .UDP_DPORT      (UDP_DPORT)
    ) u_mac (
        .i_status_valid(status_valid),.i_status_data(status_data),.o_status_pop(status_pop),
        .i_frame_valid(desc_valid),.i_frame_id(desc_id),.o_frame_pop(desc_pop),
        .o_frame_done(o_frame_tx_done),.o_frame_done_id(o_frame_tx_id),

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
