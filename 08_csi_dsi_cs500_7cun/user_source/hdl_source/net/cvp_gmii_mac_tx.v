/*
 * ============================================================================
 * cvp_gmii_mac_tx —— 极简千兆 GMAC 发送 + RGMII 串化（自研，调试专用）
 *
 * 功能：从 8bit 异步 FIFO 取固定 1440B 像素数据，前置 6B 应用头，打包成
 *   前导7×55 + SFD(D5) | ETH14B | IP20B | UDP8B | 应用头6B | 数据1440B | FCS4B
 *   UDP 载荷 = 1446B，以太网帧 1488B，线上 1500B。
 *
 * 应用头（大端，MAC 域自维护包序/帧序）：
 *   byte0 frame_seq 帧计数（mod 256，每发满 PKTS_PER_FRAME 包 +1）
 *   byte1 fmt       0x01 = RGB888 连续帧流
 *   byte2..5 offset 本包数据在整帧字节流中的偏移 = 包序*DATA_BYTES
 *
 * 流控（信用机制）：FIFO 非空 ≠ 有整包，因此像素域每写满 DATA_BYTES 字节
 *   置一次 Gray 码信用 i_credit_gray；本模块同步后按"信用-已发包数"决定
 *   是否开新包，保证起包时 FIFO 里至少有一个整包，读侧不会断流。
 *
 * 其他：
 *   - IP 首部校验和 elaboration 期由参数算出；UDP 校验和填 0（IPv4 允许）；
 *   - 无重试/无流控/无统计，调试够用；
 *   - RGMII DDR：posedge 半字节 txd[3:0]，negedge txd[7:4]，TXC 经 ODDR 正相
 *     转发。YT8531 若未使能 RX 方向内部延时 strap，千兆可能 CRC 错，届时再
 *     启用 ODELAY 或改 strap。
 *
 * 流水线（关键，别打乱）：
 *   周期 k：r_idx=k 选出 w_next_byte（线上位置 k 的字节），CRC 同拍更新；
 *   周期 k+1：r_tx_byte / r_tx_en（TX_EN 从前导码第一字节起，覆盖到 FCS 末）；
 *   周期 k+2：r_out_d / r_out_e → ODDR 出管脚。
 *   FIFO 弹出提前一拍：rd_en 在数据区前一拍打出，rd_valid（读寄存一拍）
 *   恰好在数据区被消费。
 * ============================================================================
 */
module cvp_gmii_mac_tx #(
    parameter integer DATA_BYTES     = 1440,   // 每包像素字节（须被 3 整除）
    parameter integer PKTS_PER_FRAME = 1920,   // 一帧的包数（IMG_W*IMG_H*3/DATA_BYTES）
    parameter [47:0]  MAC_DST = 48'hFF_FF_FF_FF_FF_FF,  // 广播：PC 无需配 ARP
    parameter [47:0]  MAC_SRC = 48'h02_1A_2B_3C_4D_5E,  // 本地管理地址
    parameter [31:0]  IP_SRC  = 32'hC0_A8_01_42,        // 192.168.1.66（板用虚拟 IP）
    parameter [31:0]  IP_DST  = 32'hC0_A8_01_64,        // 192.168.1.100（PC 静态 IP）
    parameter [15:0]  UDP_SPORT = 16'd6000,
    parameter [15:0]  UDP_DPORT = 16'd6000
) (
    input  wire        i_clk,        // 125MHz GMII
    input  wire        i_rst,        // 高有效（顶层已按域同步）

    /* ---- payload FIFO 读侧（cvp_async_fifo，8bit，纯像素字节流） ---- */
    input  wire [6:0]  i_credit_gray,// 像素域"整块信用"Gray 计数
    output wire        o_rd_en,      // 组合输出：与 w_next_byte 的 mux 同拍对齐
    input  wire        i_rd_empty,
    input  wire        i_rd_valid,   // cvp_async_fifo 读侧寄存一拍
    input  wire [7:0]  i_rd_data,

    /* ---- RGMII 输出 ---- */
    input  wire        i_txd_swap,   // 1=交换 ODDR d0/d1 端口映射（硅片语义排查用，SW2）
    input  wire [15:0] i_dbg_flags,  // 心跳包载荷（16bit 标志，低/高字节交替填充）
    input  wire [15:0] i_scan_word,  // 心跳载荷：I2C 扫描位图旋转窗（顶层按页旋转）
    output wire [3:0]  o_rgmii_txd,
    output wire        o_rgmii_tx_ctl,
    output wire        o_rgmii_txc,

    /* ---- 观测 ---- */
    output reg         o_tx_pkt,     // 每包起始打一拍（LED 闪烁用）
    output reg         o_hb_pkt      // 心跳包起始脉冲（顶层旋转扫描窗用）
);

    /* ---------------- 长度参数 ---------------- */
    localparam integer PRE_LEN    = 8;
    localparam integer ETH_HDR    = 14;
    localparam integer IP_HDR     = 20;
    localparam integer UDP_HDR    = 8;
    localparam integer APP_HDR    = 6;
    localparam [15:0]  UDP_LEN_I  = UDP_HDR + APP_HDR + DATA_BYTES;   // 1454
    localparam [15:0]  IP_TOTAL_I = IP_HDR + UDP_LEN_I;               // 1474
    localparam integer FRAME_LEN  = ETH_HDR + IP_TOTAL_I;             // 1488
    localparam integer APP_BEG    = PRE_LEN + ETH_HDR + IP_HDR + UDP_HDR; // 50：应用头线上位置
    localparam integer PAY_BEG    = APP_BEG + APP_HDR;                // 56：数据线上位置
    localparam integer FCS_BEG    = PRE_LEN + FRAME_LEN;              // 1496
    localparam integer TOTAL_LEN  = FCS_BEG + 4;                      // 1500
    localparam integer IFG_CYC    = 12;   // 96 BT @1G

    /* ---------------- IP 首部校验和（elaboration 期常数折叠） ---------------- */
    function [15:0] ip_cksum_f;
        input dummy;
        reg [31:0] s;
        begin
            // 逐 16bit 求和：45 00 | TotalLen | ID | Frag | TTL:Proto | Src | Dst
            s = 16'h4500
              + IP_TOTAL_I[15:0]
              + 16'h0000 + 16'h0000
              + {8'h40, 8'h11}
              + IP_SRC[31:16] + IP_SRC[15:0]
              + IP_DST[31:16] + IP_DST[15:0];
            ip_cksum_f = ~(s[31:16] + s[15:0]);
        end
    endfunction
    wire [15:0] W_IP_CKSUM = ip_cksum_f(1'b0);

    /* ---------------- 帧头字节表（帧内偏移 0..41） ---------------- */
    function [7:0] hdr_byte;
        input [7:0] idx;
        begin
            case (idx)
                8'd0: hdr_byte = MAC_DST[47:40];  8'd1: hdr_byte = MAC_DST[39:32];
                8'd2: hdr_byte = MAC_DST[31:24];  8'd3: hdr_byte = MAC_DST[23:16];
                8'd4: hdr_byte = MAC_DST[15:8];   8'd5: hdr_byte = MAC_DST[7:0];
                8'd6: hdr_byte = MAC_SRC[47:40];  8'd7: hdr_byte = MAC_SRC[39:32];
                8'd8: hdr_byte = MAC_SRC[31:24];  8'd9: hdr_byte = MAC_SRC[23:16];
                8'd10: hdr_byte = MAC_SRC[15:8];  8'd11: hdr_byte = MAC_SRC[7:0];
                8'd12: hdr_byte = 8'h08;          8'd13: hdr_byte = 8'h00;
                8'd14: hdr_byte = 8'h45;
                8'd15: hdr_byte = 8'h00;
                8'd16: hdr_byte = IP_TOTAL_I[15:8]; 8'd17: hdr_byte = IP_TOTAL_I[7:0];
                8'd18: hdr_byte = 8'h00;          8'd19: hdr_byte = 8'h00;
                8'd20: hdr_byte = 8'h00;          8'd21: hdr_byte = 8'h00;
                8'd22: hdr_byte = 8'h40;          8'd23: hdr_byte = 8'h11;
                8'd24: hdr_byte = W_IP_CKSUM[15:8]; 8'd25: hdr_byte = W_IP_CKSUM[7:0];
                8'd26: hdr_byte = IP_SRC[31:24];  8'd27: hdr_byte = IP_SRC[23:16];
                8'd28: hdr_byte = IP_SRC[15:8];   8'd29: hdr_byte = IP_SRC[7:0];
                8'd30: hdr_byte = IP_DST[31:24];  8'd31: hdr_byte = IP_DST[23:16];
                8'd32: hdr_byte = IP_DST[15:8];   8'd33: hdr_byte = IP_DST[7:0];
                8'd34: hdr_byte = UDP_SPORT[15:8]; 8'd35: hdr_byte = UDP_SPORT[7:0];
                8'd36: hdr_byte = UDP_DPORT[15:8]; 8'd37: hdr_byte = UDP_DPORT[7:0];
                8'd38: hdr_byte = UDP_LEN_I[15:8]; 8'd39: hdr_byte = UDP_LEN_I[7:0];
                8'd40: hdr_byte = 8'h00;          8'd41: hdr_byte = 8'h00;
                default: hdr_byte = 8'h00;
            endcase
        end
    endfunction

    /* ---------------- CRC-32（Ethernet reflected，逐字节） ---------------- */
    function [31:0] crc32_byte;
        input [31:0] c;
        input [7:0]  d;
        integer k;
        reg [31:0] x;
        begin
            x = c ^ {24'h0, d};
            for (k = 0; k < 8; k = k + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc32_byte = x;
        end
    endfunction

    /* ---------------- 包序 / 帧序 / 偏移（应用头） ---------------- */
    localparam integer PKT_SEQ_W = $clog2(PKTS_PER_FRAME); // 帧内包序位宽(原工程720p=11位; 1080p每帧4320包需13位, 11位会使帧尾判断永不成立)
reg [PKT_SEQ_W-1:0] r_pkt_seq;     // 帧内包序 0..PKTS_PER_FRAME-1
    reg [7:0]  r_frame_seq;   // 已发整帧计数（mod 256）
    reg [2:0]  r_hb_seq;      // 心跳序号（mod 8，与顶层扫描页对应）
    reg [31:0] r_off;         // 本包数据偏移
    reg [47:0] r_app_hdr;     // {frame_seq, fmt, offset[31:24]..[7:0]}

    /* ---------------- 信用：像素域整块计数（Gray 跨域） ---------------- */
    reg [6:0] r_cred_s1, r_cred_s2;
    always @(posedge i_clk) begin
        r_cred_s1 <= i_credit_gray;
        r_cred_s2 <= r_cred_s1;
    end
    function [6:0] gray2bin;
        input [6:0] g;
        begin
            gray2bin[6] = g[6];
            gray2bin[5] = g[5] ^ g[6];
            gray2bin[4] = g[4] ^ g[5] ^ g[6];
            gray2bin[3] = g[3] ^ g[4] ^ g[5] ^ g[6];
            gray2bin[2] = g[2] ^ g[3] ^ g[4] ^ g[5] ^ g[6];
            gray2bin[1] = g[1] ^ g[2] ^ g[3] ^ g[4] ^ g[5] ^ g[6];
            gray2bin[0] = g[0] ^ g[1] ^ g[2] ^ g[3] ^ g[4] ^ g[5] ^ g[6];
        end
    endfunction
    wire [6:0] w_cred_bin = gray2bin(r_cred_s2);
    reg  [6:0] r_cred_pop;    // 已取走整块数（mod 128）
    wire [6:0] w_cred_avail = w_cred_bin - r_cred_pop;   // 模 128 差值

    /* ---------------- 发送主状态机 ---------------- */
    reg [11:0] r_idx;
    reg        r_sending;
    reg [4:0]  r_ifg;
    reg [31:0] r_crc;

    wire w_last       = r_sending && (r_idx == TOTAL_LEN - 1);
    wire [7:0] w_fcs_b = (~r_crc) >> ((r_idx - FCS_BEG) * 8);   // 低位字节先发

    /* 应用头 6 字节选择（线上位置 50..55） */
    function [7:0] app_byte;
        input [7:0] sel;   // 0..5
        begin
            case (sel)
                8'd0: app_byte = r_app_hdr[47:40];
                8'd1: app_byte = r_app_hdr[39:32];
                8'd2: app_byte = r_app_hdr[31:24];
                8'd3: app_byte = r_app_hdr[23:16];
                8'd4: app_byte = r_app_hdr[15:8];
                8'd5: app_byte = r_app_hdr[7:0];
                default: app_byte = 8'h00;
            endcase
        end
    endfunction

    /* ---------------- 心跳：视频静默时周期性上报链路状态 ----------------
     * 超过 HB_CYCLES（~0.5s）没有正常发包 → 发一个 fmt=0x02 的状态包：
     * 载荷 = i_dbg_flags 重复，不占用 FIFO/信用。有正常包时计时清零。 */
    localparam [25:0] HB_CYCLES = 26'd62_500_000;   // 0.5s @125MHz
    reg  [25:0] r_hb_cnt;
    reg         r_hb_mode;                          // 当前包是心跳包

    /* 心跳载荷（r_idx 从 PAY_BEG 起）：byte0=flags 低, byte1=flags 高,
     * byte2=心跳序号, byte3+=扫描字（低/高交替）。注意用"载荷内偏移"判断，
     * r_idx==0 是前导码位置（上一版就是这里写错导致载荷全是扫描字）。 */
    wire [11:0] w_pay_pos = r_idx - PAY_BEG;
    wire [7:0] w_hb_byte =
        (w_pay_pos == 12'd0) ? i_dbg_flags[7:0]  :
        (w_pay_pos == 12'd1) ? i_dbg_flags[15:8] :
        (w_pay_pos == 12'd2) ? {5'b0, r_hb_seq}  :
        (r_idx[0])           ? i_scan_word[15:8] :
                               i_scan_word[7:0];

    wire [7:0] w_next_byte =
        (r_idx <  PRE_LEN) ? ((r_idx == PRE_LEN - 1) ? 8'hD5 : 8'h55) :
        (r_idx <  APP_BEG) ? hdr_byte(r_idx[7:0] - PRE_LEN[7:0]) :
        (r_idx <  PAY_BEG) ? app_byte(r_idx[7:0] - APP_BEG[7:0]) :
        (r_idx <  FCS_BEG) ? (r_hb_mode ? w_hb_byte : i_rd_data) :
                             w_fcs_b;

    // CRC 覆盖 DA..payload（线上位置 8..FCS_BEG-1）
    wire w_crc_ce = (r_idx >= PRE_LEN) && (r_idx < FCS_BEG);
    // FIFO 弹出（组合）：本拍弹、下拍 rd_valid、同拍被 mux 消费的位置对齐
    //   pop 位置区间 [PAY_BEG-1, FCS_BEG-2] → rd_valid 落在 [PAY_BEG, FCS_BEG-1]
    //   心跳包不从 FIFO 取数
    assign o_rd_en = r_sending && !r_hb_mode &&
                     (r_idx >= PAY_BEG - 1) && (r_idx < FCS_BEG - 1);

    reg [7:0] r_tx_byte;
    reg       r_tx_en;

    always @(posedge i_clk) begin
        if (i_rst) begin
            r_idx       <= 12'd0;
            r_sending   <= 1'b0;
            r_ifg       <= 5'd0;
            r_crc       <= 32'hFFFF_FFFF;
            r_tx_byte   <= 8'h00;
            r_tx_en     <= 1'b0;
            o_tx_pkt    <= 1'b0;
            o_hb_pkt    <= 1'b0;
            r_hb_seq    <= 3'd0;
            r_pkt_seq   <= 'd0;
            r_frame_seq <= 8'd0;
            r_off       <= 32'd0;
            r_app_hdr   <= 48'h01_00_00_00_00_00;
            r_cred_pop  <= 7'd0;
            r_hb_cnt    <= 26'd0;
            r_hb_mode   <= 1'b0;
        end else begin
            o_tx_pkt  <= 1'b0;
            o_hb_pkt  <= 1'b0;

            if (!r_sending) begin
                r_tx_en <= 1'b0;
                /* 心跳计时：空闲每拍推进；发包（正常/心跳）时清零 */
                if (r_hb_cnt < HB_CYCLES)
                    r_hb_cnt <= r_hb_cnt + 26'd1;
                if (r_ifg != IFG_CYC[4:0]) begin
                    r_ifg <= r_ifg + 5'd1;
                end else if (w_cred_avail >= 7'd1) begin
                    /* 开新包：锁存应用头，取一块信用，推进包/帧序
                     * (v11d: 正常发包不再清心跳计时 —— 心跳改为每 0.5s 无条件
                     *  发一包, 否则视频连续时永远静默, 诊断 scan word 无法上报) */
                    r_sending  <= 1'b1;
                    r_idx      <= 12'd0;
                    r_crc      <= 32'hFFFF_FFFF;
                    o_tx_pkt   <= 1'b1;
                    r_hb_mode  <= 1'b0;
                    r_cred_pop <= r_cred_pop + 7'd1;
                    r_app_hdr  <= {r_frame_seq, 8'h01, r_off[31:24], r_off[23:16],
                                   r_off[15:8], r_off[7:0]};
                    if (r_pkt_seq == PKTS_PER_FRAME - 1) begin
                        r_pkt_seq   <= 'd0;
                        r_frame_seq <= r_frame_seq + 8'd1;
                        r_off       <= 32'd0;
                    end else begin
                        r_pkt_seq <= r_pkt_seq + 1'b1;
                        r_off     <= (r_pkt_seq + 1'b1) * DATA_BYTES;
                    end
                end else if (r_hb_cnt >= HB_CYCLES) begin
                    /* 视频静默超时：发心跳状态包（fmt=0x02，不吃信用） */
                    r_sending  <= 1'b1;
                    r_idx      <= 12'd0;
                    r_crc      <= 32'hFFFF_FFFF;
                    o_tx_pkt   <= 1'b1;
                    o_hb_pkt   <= 1'b1;
                    r_hb_mode  <= 1'b1;
                    r_hb_cnt   <= 26'd0;
                    r_hb_seq   <= r_hb_seq + 3'd1;
                    r_app_hdr  <= {r_frame_seq, 8'h02, 32'd0};
                end
            end else begin
                r_tx_byte <= w_next_byte;
                /* TX_EN 必须覆盖整个前导码+SFD（IEEE 802.3 GMII/RGMII：
                 * EN 升起后的字节流 = 前导 7×55 + SFD D5 + ...）。
                 * 原来从 SFD 才拉 EN，PHY 视角是"无前导帧"，全部被丢。 */
                r_tx_en   <= 1'b1;
                r_crc     <= w_crc_ce ? crc32_byte(r_crc, w_next_byte) : r_crc;

                if (w_last) begin
                    r_sending <= 1'b0;
                    r_hb_mode <= 1'b0;
                    r_idx     <= 12'd0;
                    r_ifg     <= 5'd0;
                end else begin
                    r_idx <= r_idx + 12'd1;
                end
            end
        end
    end

    /* ---------------- RGMII DDR 输出 ----------------
     * ODDR 语义（TD sim_release 模型）：d0=posedge 数据、d1=negedge 数据，
     * 且都在各自沿"采样沿前"的值——同沿寄存器直喂会使高半字节早半个周期
     * 出现在引脚上（negedge 先看到新字节）。因此高半字节（和 TX_EN）先在
     * negedge 重打一拍，保证同一 TXC 周期里引脚 = {低半字节, 高半字节} 同字节。 */
    reg [7:0] r_out_d;
    reg       r_out_e;
    reg [3:0] r_out_hi;      // 高半字节 negedge 重注册
    reg       r_out_e_hi;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            r_out_d <= 8'h00;
            r_out_e <= 1'b0;
        end else begin
            r_out_d <= r_tx_byte;
            r_out_e <= r_tx_en;
        end
    end

    always @(negedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            r_out_hi   <= 4'h0;
            r_out_e_hi <= 1'b0;
        end else begin
            r_out_hi   <= r_out_d[7:4];
            r_out_e_hi <= r_out_e;
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : rgmii_out
            PH1P_LOGIC_HD_ODDR #(
                .ASYNCRST ("ENABLE")
            ) u_oddr_d (
                .clk (i_clk),
                .rst (i_rst),
                .d1  (i_txd_swap ? r_out_d[gi]  : r_out_hi[gi]),  // d1=negedge：TXD[7:4]
                .d0  (i_txd_swap ? r_out_hi[gi] : r_out_d[gi]),   // d0=posedge：TXD[3:0]
                .q   (o_rgmii_txd[gi])
            );
        end
    endgenerate

    PH1P_LOGIC_HD_ODDR #(
        .ASYNCRST ("ENABLE")
    ) u_oddr_ctl (
        .clk (i_clk),
        .rst (i_rst),
        .d1  (r_out_e_hi),
        .d0  (r_out_e),
        .q   (o_rgmii_tx_ctl)
    );

    PH1P_LOGIC_HD_ODDR #(
        .ASYNCRST ("ENABLE")
    ) u_oddr_txc (
        .clk (i_clk),
        .rst (i_rst),
        .d1  (i_txd_swap ? 1'b1 : 1'b0),   // 常规：d0=posedge→1（TXC 上升沿与低半字节对齐）
        .d0  (i_txd_swap ? 1'b0 : 1'b1),   // 交换：d1=posedge→1
        .q   (o_rgmii_txc)
    );

endmodule
