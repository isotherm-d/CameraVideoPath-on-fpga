/*
 * ============================================================================
 * cvp_mdio_ro —— MDIO 管理引擎（自研；虽沿用旧名，已支持读+写）
 *
 * 功能：
 *   1) 上电引导序列（一次性）：把 YT8531 的 EXT_0xA001.bit8（Rxc_dly_en，
 *      PHY 对 MAC 方向 RX_CLK 加 2ns 延时）读-改-写置 1——该位默认"随 strap"，
 *      板上 YT8531DC-CA 的 strap 丝印与手册有出入，直接用 MDIO 强制，
 *      消除 RGMII 采样延时不确定性：
 *        W 0x1E = 0xA001（EXT 地址寄存器）
 *        R 0x1F          （读回原值）
 *        W 0x1F = 原值 | 0x0100
 *        W 0x1E = 0xA001
 *        R 0x1F          （读回最终值 → o_ext_a001，bit8 供 LED3 显示）
 *   2) 之后循环读 Reg1(BMSR).bit2 → o_link（LED1）。
 *
 * EXT 寄存器访问方法：地址寄存器 0x1E + 数据寄存器 0x1F（YT8531 手册 6.2.2，
 * BMSR.bit0 Extended_Capability 指示）。
 *
 * MDC = i_clk/(2*CLK_DIV)（100MHz、20 分频 → 2.5MHz）。写帧 TA=10（驱动），
 * 读帧 TA=ZZ（释放，PHY 驱动数据）；引脚变化在 MDC 下降沿，采样在上升沿前。
 * ============================================================================
 */
module cvp_mdio_ro #(
    parameter integer CLK_DIV  = 20,
    parameter [4:0]  PHY_ADDR  = 5'd1
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    output reg         o_mdc,
    output reg         o_mdio_o,
    output reg         o_mdio_oe,
    input  wire        i_mdio_i,
    output reg         o_link,          // 1=链路建立（Reg1.bit2）
    output reg  [15:0] o_ext_a001       // EXT_0xA001 最终读回值（bit8=Rxc_dly_en）
);

    /* ---------------- MDC 相位发生 ---------------- */
    localparam integer PHW = 2 * CLK_DIV;
    reg [7:0] r_phase;
    wire w_mdc_rise = (r_phase == 8'd0);
    wire w_mdc_fall = (r_phase == CLK_DIV);
    wire w_pre_rise = (r_phase == PHW - 1);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) r_phase <= 8'd0;
        else          r_phase <= (r_phase == PHW - 1) ? 8'd0 : r_phase + 8'd1;
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) o_mdc <= 1'b0;
        else if (w_mdc_rise) o_mdc <= 1'b1;
        else if (w_mdc_fall) o_mdc <= 1'b0;
    end

    /* ---------------- 命令调度 ----------------
     * cmd 0..4：EXT_0xA001 读改写+回读；cmd 5：循环读 BMSR。
     * {is_write, regad, 固定数据}；cmd1/4/5 为读。 */
    localparam CMD_EXT_ADDR1 = 3'd0,
               CMD_EXT_RD1   = 3'd1,
               CMD_EXT_WR1   = 3'd2,
               CMD_EXT_ADDR2 = 3'd3,
               CMD_EXT_RD2   = 3'd4,
               CMD_LINK      = 3'd5;
    reg [2:0] r_cmd;

    wire        w_is_write = (r_cmd == CMD_EXT_ADDR1) || (r_cmd == CMD_EXT_WR1) ||
                             (r_cmd == CMD_EXT_ADDR2);
    wire [4:0]  w_regad_e  = (r_cmd == CMD_EXT_ADDR1 || r_cmd == CMD_EXT_ADDR2)
                             ? 5'd30                      // 0x1E 地址寄存器
                             : (r_cmd == CMD_LINK ? 5'd1 : 5'd31); // BMSR / 0x1F 数据
    reg  [15:0] r_ext_rd1;      // 第一次读回的 EXT_0xA001

    wire [15:0] w_wr_data = (r_cmd == CMD_EXT_ADDR1 || r_cmd == CMD_EXT_ADDR2)
                            ? 16'hA001
                            : (r_ext_rd1 | 16'h0100);

    wire [2:0]  w_next_cmd = (r_cmd == CMD_LINK) ? CMD_LINK : r_cmd + 3'd1;

    /* ---------------- 帧位流（64bit：32 前导 + 32 帧体） ----------------
     * 帧体：ST=01 | OP(w=01,r=10) | PA[4:0] | RA[4:0] | TA | DATA[15:0] */
    reg [5:0]  r_bit;           // 0..63
    reg [15:0] r_rd_shr;        // 读数据移位
    reg        r_rd_pend;       // 本帧是读

    wire [1:0] w_op     = w_is_write ? 2'b01 : 2'b10;
    wire       w_in_ta  = (r_bit >= 6'd46);
    wire       w_in_dat = (r_bit >= 6'd48);
    // 帧体位值（TA/data 段写时用移位，读时输出任意）
    wire [5:0] w_body_bit = r_bit - 6'd32;              // 0..31
    wire       w_body_val =
        (w_body_bit < 6'd2)  ? (w_body_bit == 6'd0) :                          // ST=01
        (w_body_bit < 6'd4)  ? w_op[3 - w_body_bit] :                          // OP
        (w_body_bit < 6'd9)  ? PHY_ADDR[6'd8 - w_body_bit] :                   // PA[4:0]
        (w_body_bit < 6'd14) ? w_regad_e[6'd13 - w_body_bit] :                 // RA[4:0]
                               1'b1;                                           // TA/data 占位
    wire [6:0] w_dat_idx  = r_bit - 6'd48;                   // 0..15

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_mdio_o  <= 1'b1;
            o_mdio_oe <= 1'b1;
            r_bit     <= 6'd0;
            r_rd_shr  <= 16'hFFFF;
            r_rd_pend <= 1'b0;
            r_ext_rd1 <= 16'h0000;
            r_cmd     <= CMD_EXT_ADDR1;
            o_link    <= 1'b0;
            o_ext_a001<= 16'h0000;
        end else begin
            /* 输出：MDC 下降沿换相。写帧全程驱动；读帧在 TA/data 段释放。 */
            if (w_mdc_fall) begin
                o_mdio_oe <= w_is_write || !w_in_ta;
                if (!w_in_ta)
                    o_mdio_o <= w_body_val;
                else if (w_is_write && w_in_dat)
                    o_mdio_o <= w_wr_data[15 - w_dat_idx];
                else if (w_is_write)                       // TA=10
                    o_mdio_o <= (r_bit == 6'd46);
                // 读帧 TA/data 段 oe=0，o_mdio_o 无效
            end

            /* 读采样：上升沿前锁存 */
            if (w_pre_rise && r_rd_pend && w_in_dat)
                r_rd_shr <= {r_rd_shr[14:0], i_mdio_i};

            /* 帧推进 */
            if (w_mdc_rise) begin
                if (r_bit == 6'd63) begin
                    /* 帧完成：按命令登记结果，并预置下一帧的读采样使能 */
                    case (r_cmd)
                        CMD_EXT_RD1: r_ext_rd1 <= r_rd_shr;
                        CMD_EXT_RD2: o_ext_a001 <= r_rd_shr;
                        CMD_LINK:    o_link <= r_rd_shr[2];
                        default: ;
                    endcase
                    r_cmd     <= w_next_cmd;
                    r_rd_pend <= (w_next_cmd == CMD_EXT_RD1) ||
                                 (w_next_cmd == CMD_EXT_RD2) ||
                                 (w_next_cmd == CMD_LINK);
                    r_bit     <= 6'd0;
                    r_rd_shr  <= 16'hFFFF;
                end else begin
                    r_bit <= r_bit + 6'd1;
                end
            end
        end
    end

endmodule
