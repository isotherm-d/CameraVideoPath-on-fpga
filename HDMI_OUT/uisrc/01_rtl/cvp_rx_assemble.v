/*
 * ============================================================================
 * cvp_rx_assemble —— PH1P35 网口视频流(UDP)重组为顺序光栅视频流 (EG4D 副板侧)
 *
 * 输入: uiudp_stack 的 UDP 载荷流 (O_R_udp_valid/O_R_udp_data, clk_125 域,
 *       无反压, 每包连续 1446B = 6B 应用头 + 1440B 像素)。
 * 输出: uidbuf 写侧视频流 (W_FS/W_wren/W_data[23:0]), 同时钟域。
 *       每两个 FS 脉冲之间恰好 IMG_W*IMG_H 个像素(uidbuf 写侧要求满帧,
 *       否则其 FDMA 状态机会停在等数据而错过下一个帧同步)。
 *
 * 线上包格式(与 PH1P35 cvp_gmii_mac_tx 一致):
 *   UDP 载荷 byte0 frame_seq | byte1 fmt(0x01=视频) | byte2..5 offset 大端
 *   像素字节序: 每像素 3 字节 R,G,B; DATA_BYTES=1440 → 480 像素/包。
 *   (协议栈 MAC 层已改放行广播IP帧; IP 层按目的IP=192.168.1.100 过滤;
 *    状态包 fmt=0x26 走端口6002 仍会被 UDP 层透出, 靠 fmt 字节在此丢弃)
 *
 * 重组算法(硬件化的 PC 端 capture_now.py, 无反压约束下变形):
 *   1. 输入侧: 解析应用头, 判定接受(fmt/界内/整包对齐/顺序/缺口白名单);
 *      接受的包 → 载荷字节压入 staging FIFO + 描述符(offset)入队;
 *      offset==0 的包额外先入队一个"帧尾描述符"(把上一帧补黑到满帧)。
 *   2. 输出侧(描述符状态机, 严格顺序):
 *      FILL: 从 r_pushed 补黑像素到本描述符 offset(丢包空洞→黑);
 *      DATA: 从 staging 弹 3 字节拼像素输出(480 个);
 *      帧尾描述符完成(pushed==FRAME_BYTES)时发 o_fs 并清零。
 *   3. 缺口容忍 4 包(白名单{0..4}×1440B): 缺口更大(连丢>4包)时后续包被丢弃直到
 *      下一个 offset==0, 上一帧尾部由帧尾描述符补黑 → 丢一帧后自恢复。
 *
 * staging 水位: FILL 期黑像素 1/拍, 输入 1B/拍, staging 入不敷出,
 * 峰值 ≈ 2 包(2.9KB) < 4096B; DATA 期弹 3B/拍 > 入 1B/拍, 迅速排空。
 * ============================================================================
 */
module cvp_rx_assemble #(
    parameter integer IMG_W       = 1280,
    parameter integer IMG_H       = 720,
    parameter integer DATA_BYTES  = 1440    // 每UDP包像素字节数(须被3整除)
)(
    input  wire        i_clk,          // 125MHz UDP 用户时钟
    input  wire        i_rst_n,

    /* UDP 载荷流(来自 uiudp_stack, 无反压, 必须逐拍消费) */
    input  wire        i_udp_valid,    // 整包期间为高(含 6B 应用头)
    input  wire [7:0]  i_udp_data,

    /* 视频流输出 → uidbuf W 侧 */
    output reg         o_w_fs,         // 帧同步, 1 拍脉冲
    output reg         o_w_de,         // 像素有效
    output reg  [23:0] o_w_rgb,        // {R,G,B}

    /* 观测 */
    output reg  [7:0]  o_frame_cnt,    // 完整输出帧计数(mod 256)
    output wire        o_pkt_act       // 收包活动(含丢弃包, LED 用)
);

    localparam integer FRAME_BYTES = IMG_W * IMG_H * 3;          // 2_764_800
    localparam integer BYTE_W      = $clog2(FRAME_BYTES+1);      // 22
    localparam integer PAY_WORDS   = DATA_BYTES / 3;             // 480

    /* ================= 输出侧状态编码(前置, 供输入侧跟踪判定引用) ============ */
    localparam [2:0] S_IDLE = 3'd0,    // 无描述符, 等待
                     S_FILL = 3'd1,    // 补黑到目标偏移
                     S_DATA = 3'd2,    // 弹 staging 输出 480 像素
                     S_FS   = 3'd3,    // 帧尾: 补黑到满帧
                     S_FSW  = 3'd4,    // FS 脉冲拉宽(uidbuf fs_cap 是 150M 域
                                       // 5 级同步+边沿检测, 1 拍窄脉冲会被漏采)
                     S_BLANK= 3'd5;    // FS 后消隐 ≥ uidbuf S_RST 的 FIFO 复位窗
                                       // (~100 拍@150M), 否则帧头像素被吞
    localparam integer FS_HOLD  = 64;  // FS 拉宽 64 拍(512ns)
    localparam integer BLANK_N  = 512; // 消隐 512 拍(4.1us)

    /* ================= 输入侧: 包头解析 + 接受判定 ================= */
    reg [2:0]        S_out;            // 输出侧状态机状态
    reg        r_prev_valid;
    reg [11:0] r_bcnt;                 // 包内字节计数(下一拍序号; 当拍序号见 w_bcnt)
    reg [47:0] r_hdr;                  // 应用头移位
    reg        r_take;                 // 本包载荷入 staging
    reg [BYTE_W-1:0] r_committed;      // 帧内已承诺字节位置(最后接受包的末尾)

    /* 当拍拼接完整应用头: w_hdr_last(bcnt==5) 那拍 byte5 还在 i_udp_data 上,
     * r_hdr 此时只含 5 字节(offset 未对齐)。用组合拼接后判定/入队同拍完成。
     * 修复: 原直接用 r_hdr → w_accept 比 w_hdr_last 晚一拍, 永远错开,
     * r_take 永不置位(仿真定位: w_hdr_last 拍 w_in_frame=0, 下一拍才=1) */
    wire [47:0] w_hdr_now = {r_hdr[39:0], i_udp_data};
    wire [7:0]  w_fmt    = w_hdr_now[39:32];
    wire [31:0] w_offset = w_hdr_now[31:0];
    /* 当拍处理的字节序号(组合): 包首拍恒为 0, 其余拍用寄存值。
     * 修复: 原 r_bcnt 在包首拍被"重置0"与"+1"双重赋值, 后者生效导致计数
     * 卡死在上一包遗留值, 零包被接受 → 帧缓冲空 → 屏显 DDR 随机内容(杂色)。 */
    wire [11:0] w_bcnt     = (i_udp_valid && !r_prev_valid) ? 12'd0 : r_bcnt;
    wire        w_hdr_last = (w_bcnt == 12'd5);

    /* 界内: offset + 一包载荷 ≤ 帧长。无符号 32bit 比较天然拒绝 bit31=1 的
     * 乱值(不会回绕成小值)。
     * 修复: 原式 ({~offset[31],offset[30:0]}+DATA_BYTES)≤FRAME_BYTES 把正常
     * 包(bit31=0)映射到 ≥0x8000_0000 → 恒拒收, 与 PC 脚本 offset<total_bytes
     * 语义正好相反(MAC 层修好后会 100% 丢包, rx_frame_cnt 恒 0)。 */
    wire       w_in_frame = (w_offset <= (FRAME_BYTES - DATA_BYTES));
    wire       w_newframe = (w_offset == 32'd0);
    wire [31:0] w_gap     = w_offset - {10'd0, r_committed};
    /* 缺口白名单 {0..4}×1440: 归纳保证接受的 offset 恒为整包(1440B)对齐
     * (committed 初值 0, 每次接受 committed=offset+DATA_BYTES), 取代原
     * offset%3 像素对齐检查——%3 会放行 1443 这类非包边界乱值造成像素错位 */
    wire       w_gap_ok   = (w_gap == 32'd0) || (w_gap == DATA_BYTES) ||
                            (w_gap == 2*DATA_BYTES) || (w_gap == 3*DATA_BYTES) ||
                            (w_gap == 4*DATA_BYTES);
    wire       w_mid_ok   = (w_offset >= {10'd0, r_committed}) && w_gap_ok;
    /* staging 水位门槛: 帧尾长补黑期间新帧包不再无限入队(4096B 会溢出且
     * 溢出丢字节会造成永久错位), 水位高则丢包, 缺口自然增大到下一帧重同步。
     * 阈值 = 4096 - 1446(一包) - 余量250 */
    wire [11:0] w_st_used;                        // 前置声明(ModelSim 严格模式要求)
    wire       w_stage_ok = (w_st_used < 12'd2400);
    /* CVP: 跟踪-丢弃 —— 通过格式/界内/顺序检查但被水位挡住的包, 推进 committed
     * 而不入队。全分辨率仿真复现板上"横断带"的根因: 一次丢包 → 帧尾/洞填充
     * (最长 74 万拍)期间 staging 无法排空, 直接拒收会让 committed 停滞, gap
     * 级联把后续帧整帧丢掉, 每帧只剩开头几包。跟踪-丢弃后填充结束即重新同步,
     * 损失只限丢包发生的那一帧。 */
    wire       w_seq_ok    = (w_newframe || w_mid_ok);
    wire       w_accept    = (w_fmt == 8'h01) && w_in_frame && w_stage_ok && w_seq_ok;
    wire       w_track_hit = (w_fmt == 8'h01) && w_in_frame && w_seq_ok && !w_stage_ok;

    /* ================= staging FIFO (字节) ================= */
    wire       w_st_we  = r_take && i_udp_valid && (w_bcnt >= 12'd6);
    wire [7:0] w_st_dout;
    wire       w_st_empty;
    wire       w_st_re;

    udp_pkg_buf #(
        .DATA_WIDTH_W      (8      ),
        .DATA_WIDTH_R      (8      ),
        .ADDR_WIDTH_W      (12     ),   // 4096 B
        .ADDR_WIDTH_R      (12     ),
        .SHOW_AHEAD_EN     (1'b1   ),
        .OUTREG_EN         ("NOREG")
    ) u_stage (
        .rst        (~i_rst_n     ),
        .clkw       (i_clk        ),
        .we         (w_st_we      ),
        .di         (i_udp_data   ),
        .clkr       (i_clk        ),
        .re         (w_st_re      ),
        .dout       (w_st_dout    ),
        .empty_flag (w_st_empty   ),
        .wrusedw    (            ),
        .rdusedw    (w_st_used    )
    );

    /* ================= 描述符队列 (单时钟, 8 深) =================
     * bit22 = 帧尾标志, bit21:0 = 目标偏移(字节) */
    localparam integer DESC_W = 23;
    reg [DESC_W-1:0] r_desc [0:7];
    reg [2:0]  r_desc_wr, r_desc_rd;
    reg [3:0]  r_desc_cnt;                       // 占用数
    /* 修复: 原声明无位宽(默认 1bit), 8-0=8 截断为 0 → w_desc_enough 恒 0,
     * 重组器永远不收包(仿真定位, 板上表现为 MAC 通后仍黑屏、frame_cnt 恒 0) */
    wire [3:0] w_desc_free  = 4'd8 - r_desc_cnt;
    wire [DESC_W-1:0] w_desc_head = r_desc[r_desc_rd];   // 修复: 原用 rd[1:0] 模4寻址,
                                                         // 队列深 8 → 越过槽4读旧数据
    wire       w_desc_enough = w_newframe ? (w_desc_free >= 4'd2) : (w_desc_free >= 4'd1);
    wire       w_desc_empty;                     // 前置声明(ModelSim 严格模式要求)
    wire       w_desc_pop;                       // 前置声明

    /* ================= 输入侧时序 ================= */
    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            r_prev_valid <= 1'b0;
            r_bcnt       <= 12'd0;
            r_hdr        <= 48'd0;
            r_take       <= 1'b0;
            r_committed  <= {BYTE_W{1'b0}};
            r_desc_wr    <= 3'd0;
            r_desc_cnt   <= 4'd0;
        end else begin
            r_prev_valid <= i_udp_valid;

            /* 描述符占用计数: 入队(输入侧) 与 出队(输出侧 S_IDLE 弹出) 同拍可发生 */
            r_desc_cnt <= r_desc_cnt
                        + (w_hdr_last && i_udp_valid && w_accept && w_desc_enough
                           ? (w_newframe ? 4'd2 : 4'd1) : 4'd0)
                        - (w_desc_pop ? 4'd1 : 4'd0);

            if (i_udp_valid) begin
                /* 头 6 字节移位捕获(用当拍序号 w_bcnt) */
                if (w_bcnt <= 12'd5)
                    r_hdr <= {r_hdr[39:0], i_udp_data};

                /* 第 6 字节到齐 → 裁决 */
                if (w_hdr_last && w_accept && w_desc_enough) begin
                    r_take <= 1'b1;
                    if (w_newframe) begin
                        /* 帧尾描述符(上一帧补黑到满帧) + 本包描述符, 各占一槽
                         * 修复: 原第二槽地址用 wr[1:0]+1(2bit 模4), wr 低2位=3 时
                         * 描述符落点比读指针超前 4 槽 → 帧尾描述符周期性丢失,
                         * S_FS 永不执行、永无 FS(仿真心跳定位: pushed 冲破 14400) */
                        /* 帧尾标志固定在 DESC_W-1(修复: 原按 BYTE_W 拼接,
                         * 小分辨率下 BYTE_W≠22 → 标志错位, 读侧 [22] 永远看不见) */
                        r_desc[r_desc_wr]                             <= {1'b1, {(DESC_W-1){1'b0}}};
                        r_desc[r_desc_wr + 3'd1]                      <= {1'b0, w_offset[BYTE_W-1:0]};
                        r_desc_wr  <= r_desc_wr + 3'd2;
                    end else begin
                        r_desc[r_desc_wr]             <= {1'b0, w_offset[BYTE_W-1:0]};
                        r_desc_wr  <= r_desc_wr + 3'd1;
                    end
                    r_committed <= w_offset[BYTE_W-1:0] + DATA_BYTES;
                end
                else if (w_hdr_last && w_track_hit) begin
                    /* 跟踪-丢弃: 只推进承诺位置(黑像素由填充覆盖), 不入队 */
                    r_committed <= w_offset[BYTE_W-1:0] + DATA_BYTES;
                end

                /* 单一赋值点: 包尾/超长钳位后归 0(下一包首拍由 w_bcnt 组合强制 0) */
                r_bcnt <= (w_bcnt >= 12'd1445) ? 12'd0 : w_bcnt + 12'd1;
            end else begin
                r_bcnt <= 12'd0;          // 包间隙归零
                r_take <= 1'b0;           // 包间隙清除(过短包防御)
            end
        end
    end

    /* ================= 输出侧状态机 ================= */
    reg [BYTE_W-1:0] r_pushed;         // 本帧已输出字节位置
    reg [BYTE_W-1:0] r_target;         // 当前描述符目标偏移
    reg [8:0]        r_wcnt;           // DATA 相内已出像素 0..479
    reg [1:0]        r_psel;           // 字节相位 0..2
    reg [23:0]       r_pxl;
    reg [9:0]        r_fscnt;          // FS 拉宽计数
    reg [9:0]        r_blankcnt;       // 消隐计数

    assign w_st_re = (S_out == S_DATA) && !w_st_empty;
    // DATA 态逐拍弹字节(SHOW_AHEAD: 本拍 dout 即当前字节)
    assign w_desc_empty = (r_desc_cnt == 4'd0);
    assign w_desc_pop   = (S_out == S_IDLE) && !w_desc_empty;   // 本拍弹出一条描述符

    assign o_pkt_act = i_udp_valid;

    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            S_out       <= S_IDLE;
            r_pushed    <= {BYTE_W{1'b0}};
            r_target    <= {BYTE_W{1'b0}};
            r_wcnt      <= 9'd0;
            r_psel      <= 2'd0;
            r_pxl       <= 24'd0;
            r_desc_rd   <= 3'd0;
            r_fscnt     <= 10'd0;
            r_blankcnt  <= 10'd0;
            o_w_de      <= 1'b0;
            o_w_rgb     <= 24'd0;
            o_w_fs      <= 1'b0;
            o_frame_cnt <= 8'd0;
        end else begin
            o_w_de <= 1'b0;
            o_w_fs <= 1'b0;

            case (S_out)
                S_IDLE: begin
                    if (!w_desc_empty) begin
                        r_target <= w_desc_head[BYTE_W-1:0];
                        r_desc_rd <= r_desc_rd + 3'd1;   // 弹出描述符
S_out    <= w_desc_head[DESC_W-1] ? S_FS : S_FILL;
                    end
                end

                S_FILL: begin
                    /* 补黑像素 1/拍, 直到 pushed == target */
                    if (r_pushed < r_target) begin
                        o_w_de  <= 1'b1;
                        o_w_rgb <= 24'h000000;
                        r_pushed <= r_pushed + 3;
                        if (r_pushed + 3 == r_target)
                            S_out <= S_DATA;
                    end else begin
                        S_out <= S_DATA;   // 无缺口直通
                    end
                    r_wcnt <= 9'd0;
                    r_psel <= 2'd0;
                end

                S_DATA: begin
                    if (!w_st_empty) begin
                        /* SHOW_AHEAD: dout 为当前字节, re 消耗之 */
                        r_pxl <= {r_pxl[15:0], w_st_dout};
                        if (r_psel == 2'd2) begin
                            o_w_de  <= 1'b1;
                            o_w_rgb <= {r_pxl[15:0], w_st_dout};
                            r_pushed <= r_pushed + 3;
                            r_psel   <= 2'd0;
                            if (r_wcnt == 9'd479)
                                S_out <= S_IDLE;
                            else
                                r_wcnt <= r_wcnt + 9'd1;
                        end else begin
                            r_psel <= r_psel + 2'd1;
                        end
                    end
                    /* staging 空: 输入比输出慢, 等待(包持续期 <1.5K 拍) */
                end

                S_FS: begin
                    /* 帧尾描述符: 从 pushed 补黑到 FRAME_BYTES, 然后进入 FS 拉宽 */
                    if (r_pushed < FRAME_BYTES) begin
                        o_w_de  <= 1'b1;
                        o_w_rgb <= 24'h000000;
                        r_pushed <= r_pushed + 3;
                    end else begin
                        r_pushed <= {BYTE_W{1'b0}};
                        r_fscnt  <= FS_HOLD[9:0];
                        S_out    <= S_FSW;
                        o_frame_cnt <= o_frame_cnt + 8'd1;
                    end
                end

                S_FSW: begin
                    /* FS 脉冲保持 FS_HOLD 拍(fs_cap 检测本脉冲的下降沿) */
                    if (r_fscnt != 10'd0) begin
                        o_w_fs  <= 1'b1;
                        r_fscnt <= r_fscnt - 10'd1;
                    end else begin
                        o_w_fs    <= 1'b0;
                        r_blankcnt<= BLANK_N[9:0];
                        S_out     <= S_BLANK;
                    end
                end

                S_BLANK: begin
                    /* 消隐: 避开 uidbuf S_RST 期间的写 FIFO 复位窗(帧头像素保护) */
                    if (r_blankcnt != 10'd0)
                        r_blankcnt <= r_blankcnt - 10'd1;
                    else
                        S_out <= S_IDLE;
                end

                default: S_out <= S_IDLE;
            endcase
        end
    end

endmodule
