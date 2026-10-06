`timescale 1ns / 1ns
/*****************************************************************
 cvp_cmd_rx —— RGMII 接收 + 极简 UDP 命令解析(v20)
 用途: 上位机/开发板发 UDP 广播命令包, 控制曝光码 / 白平衡增益 / 模式。

 接收链: RGMII RX(IDDR x5 @RXCK 125M) -> 字节流 -> 过滤状态机
         -> 命令事件(toggle+data 跨域) -> 100M 域命令寄存器组

 过滤规则(任一不符即丢帧, 状态回等下一帧):
   字节偏移包含 7 字节前导码和 SFD，以下为线上的实际偏移：
   字节 7      = 0xD5            (SFD; 前导不逐字节查, 只查 SFD)
   字节 20-21  = 0x08 0x00       (EtherType = IPv4)
   字节 31     = 0x11            (协议 = UDP)
   字节 44-45  = 0x17 0x71       (UDP 目的端口 = 6001)
   字节 50-53  = C5 A5 50 01     (魔数)
   字节 54     = 命令码
   字节 55-57  = 值 24bit 大端
 不查 MAC/IP 地址(命令走广播, 宽容上位机与开发板混用)。

 命令集(载荷为魔数4字节 + 命令1字节 + 数值3字节):
   0: 模式      值 0=手动(ae_set 按键) 1=自动(cvp_ae 闭环) 2=网络曝光值
   1: 曝光码    值 16bit = 寄存器码(半行); v23 起由 cvp_proc 消费(钳位 62..1800
                后重写传感器), 并发 o_exp_wr 单拍
   2/3/4:      GAIN_R/G/B  值 9bit Q8(256=1.0x, 上限 511)
   5:           SWAP_RB     值 0/1
 输出(100M 域稳定寄存器, 供 cvp_proc(曝光) / color_correct(白平衡)):
   o_mode[1:0] 0=按键 1=自动 2=网络
   o_net_ae[15:0]  o_gain_r/g/b[8:0]  o_swap
*****************************************************************/
module cvp_cmd_rx (
    /* RGMII 接收(RXCK 域) */
    input          I_rxclk,        // PHY RXC 125M
    input          I_rst_n_rx,
    input  [3:0]   I_rxd,
    input          I_rxctl,        // 帧内=1(载波)
    input          I_rst_n_gmii,   // 100M 域复位
    input          I_clk_gmii,     // 125M GMII(与 RXCK 同频不同源, 经同步器交互)

    /* 100M 域命令寄存器输出 */
    input          I_clk100,
    input          I_rst_n_100,
    output reg  [1:0]  o_mode,
    output reg  [15:0] o_net_ae,
    output reg  [8:0]  o_gain_r,
    output reg  [8:0]  o_gain_g,
    output reg  [8:0]  o_gain_b,
    output reg         o_swap,
    output reg         o_awb_en,     // v21: 0=冻结 AWB(手动白平衡), 1=自动
    output reg  [6:0]  o_kelvin,     // v21: 色温, 单位 100K(25..100 = 2500K..10000K)
    output reg         o_exp_wr,     // v23: 曝光命令单拍(100M 域, 通知 cvp_proc 重写传感器)
    output reg  [7:0]  o_evt_cnt
);

    /* ================= 1. IDDR: RGMII DDR 采样 ================= */
    wire q0_d0, q1_d0, q0_d1, q1_d1, q0_d2, q1_d2, q0_d3, q1_d3, q0_c, q1_c;

    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_idd0 (.clk(I_rxclk), .d(I_rxd[0]), .q0(q0_d0), .q1(q1_d0), .rst(!I_rst_n_rx));
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_idd1 (.clk(I_rxclk), .d(I_rxd[1]), .q0(q0_d1), .q1(q1_d1), .rst(!I_rst_n_rx));
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_idd2 (.clk(I_rxclk), .d(I_rxd[2]), .q0(q0_d2), .q1(q1_d2), .rst(!I_rst_n_rx));
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_idd3 (.clk(I_rxclk), .d(I_rxd[3]), .q0(q0_d3), .q1(q1_d3), .rst(!I_rst_n_rx));
    PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE")) u_iddc (.clk(I_rxclk), .d(I_rxctl), .q0(q0_c),  .q1(q1_c),  .rst(!I_rst_n_rx));

    // 字节组装: RGMII 每拍 1 字节 —— RXD[x] posedge 位=字节 bit[x](低 nibble),
    // negedge 位=字节 bit[x+4](高 nibble)。
    wire [7:0] w_byte = {q1_d3, q1_d2, q1_d1, q1_d0, q0_d3, q0_d2, q0_d1, q0_d0};
    wire       w_en   = q0_c;              // RX_DV(posedge 位, 帧内=1)
    reg        en_d1;                      // DV 延迟一拍(帧沿检测)
    always @(posedge I_rxclk or negedge I_rst_n_rx) begin
        if (!I_rst_n_rx) en_d1 <= 1'b0;
        else             en_d1 <= w_en;
    end

    /* ================= 2. 字节流过滤状态机(RXCK 域) ================= */
    reg [7:0]  r_idx;         // 帧内字节计数
    reg        r_fail;        // 本帧过滤失败
    reg        r_arm;         // 载荷窗口使能(全部校验通过)
    reg [23:0] r_val;         // 命令值
    reg [7:0]  r_cmd;
    reg        r_evt;         // 命令事件(单拍, RXCK 域)

    reg        r_frame_cnt = 8'd0;
    wire w_sof    = w_en && !en_d1;             // 帧开始(RX_DV 上升沿)
    wire w_eof    = !w_en && en_d1;             // 帧结束

    // 字节有效: en 高的字节(idx 0..) + en_d 高 en 低(帧尾 CRC 首字节, 忽略)
    wire w_bval   = w_en;

    localparam [7:0] M0 = 8'hC5, M1 = 8'hA5, M2 = 8'h50, M3 = 8'h01;

    always @(posedge I_rxclk or negedge I_rst_n_rx) begin
        if (!I_rst_n_rx) begin
            r_idx <= 0; r_fail <= 0; r_arm <= 0;
            r_val <= 0; r_cmd <= 0; r_evt <= 0;
            o_evt_cnt <= 8'd0;
        end else begin
            r_evt <= 1'b0;
            if (r_evt) o_evt_cnt <= o_evt_cnt + 8'd1;
            if (w_sof || w_eof) begin
                r_idx <= 0; r_fail <= 0; r_arm <= 0;
            end else if (w_bval) begin
                r_idx <= r_idx + 8'd1;
                case (r_idx)
                    /* r_idx 空间: sof(RX_CTL 上升沿)拍吃掉前导[0]并清零,
                     * 此后 r_idx = 帧内偏移-1。所有校验按此空间:
                     *   D5=6, EthType=19/20, IP协议=30, 端口=43/44,
                     *   魔数=49..52, 命令=53, 值=54..56, evt=56 */
                    8'd6:  if (w_byte != 8'hD5) r_fail <= 1'b1;   // SFD
                    8'd19: if (w_byte != 8'h08) r_fail <= 1'b1;   // EthType hi
                    8'd20: if (w_byte != 8'h00) r_fail <= 1'b1;   // EthType lo
                    8'd30: if (w_byte != 8'h11) r_fail <= 1'b1;   // IP 协议 = UDP
                    8'd43: if (w_byte != 8'h17) r_fail <= 1'b1;   // UDP 目的端口 hi (6001)
                    8'd44: if (w_byte != 8'h71) r_fail <= 1'b1;   // UDP 目的端口 lo
                    8'd49: if (w_byte != M0)    r_fail <= 1'b1;   // 魔数 0
                    8'd50: if (w_byte != M1)    r_fail <= 1'b1;   // 魔数 1
                    8'd51: if (w_byte != M2)    r_fail <= 1'b1;   // 魔数 2
                    8'd52: if (w_byte != M3)    r_fail <= 1'b1;   // 魔数 3
                    8'd53: begin
                               r_cmd <= w_byte;
                               r_arm <= !r_fail;               // 前置校验全过才武装
                           end
                    8'd54: if (r_arm) r_val[23:16] <= w_byte;
                    8'd55: if (r_arm) r_val[15:8] <= w_byte;
                    8'd56: if (r_arm) begin
                               r_val[7:0]  <= w_byte;
                               r_evt       <= 1'b1;      // 三个数值字节全部到齐才提交
                           end
                    default: ;
                endcase
            end
        end
    end

    reg        r_tgl;
    reg        s_t1, s_t2;
    reg [31:0] s_data1, s_data2;
    wire [31:0] w_evt_data = {r_cmd, r_val[23:0]};

    always @(posedge I_rxclk or negedge I_rst_n_rx) begin
        if (!I_rst_n_rx) r_tgl <= 1'b0;
        else if (r_evt)  r_tgl <= ~r_tgl;
    end
    always @(posedge I_rxclk or negedge I_rst_n_rx) begin
        if (!I_rst_n_rx) s_data1 <= 32'd0;
        else if (r_evt)  s_data1 <= w_evt_data;      // 数据与 toggle 同拍更新, 翻转沿前已稳定
    end

    /* ================= 4. 100M 域: 同步 + 命令寄存器 ================= */
    reg        s_tg1, s_tg2, s_tg3;
    reg [31:0] s_dt1, s_dt2;
    wire       w_sync_edge = (s_tg2 != s_tg3);   // 同步后的翻转沿
    reg        r_ev_d;

    wire [7:0]  w_cmd  = s_dt2[31:24];
    wire [23:0] w_val  = s_dt2[23:0];
    wire [16:0] w_exp_v = w_val[16:0];

    always @(posedge I_clk100 or negedge I_rst_n_100) begin
        if (!I_rst_n_100) begin
            s_tg1 <= 0; s_tg2 <= 0; s_tg3 <= 0;
            s_dt1 <= 0; s_dt2 <= 0;
            o_mode    <= 2'd0;
            o_net_ae  <= 16'd1700;
            o_gain_r  <= 9'd438;    // v23: 与 color_correct 标定一致(白平衡 x1.506 补光)
            o_gain_g  <= 9'd386;
            o_gain_b  <= 9'd371;
            o_swap    <= 1'b0;
            o_awb_en  <= 1'b1;
            o_kelvin  <= 7'd65;   // 默认 6500K
            o_exp_wr  <= 1'b0;
            r_ev_d    <= 1'b0;
        end else begin
            s_tg1 <= r_tgl;  s_tg2 <= s_tg1;  s_tg3 <= s_tg2;   // toggle 双拍
            s_dt1 <= s_data1; s_dt2 <= s_dt1;                    // 数据直过(翻转前已稳定)
            r_ev_d <= w_sync_edge;
            o_exp_wr <= 1'b0;
            if (w_sync_edge && !r_ev_d) begin                    // 新命令
                case (w_cmd)
                    8'd0:    o_mode   <= w_val[1:0];
                    8'd1:    o_net_ae <= w_val[15:0];
                    8'd2:    o_gain_r <= w_val[8:0];
                    8'd3:    o_gain_g <= w_val[8:0];
                    8'd4:    o_gain_b <= w_val[8:0];
                    8'd5:    o_swap   <= w_val[0];
                    8'd6:    o_awb_en <= w_val[0];
                    8'd7:    o_kelvin <= w_val[6:0];
                    default: ;
                endcase
                if (w_cmd == 8'd1)
                    o_exp_wr <= 1'b1;   // 曝光命令: 单拍通知(o_net_ae 同拍已更新)
            end
        end
    end

endmodule
