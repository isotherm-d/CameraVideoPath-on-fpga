`timescale 1ns / 1ns
/*****************************************************************
 wb_kelvin —— 色温(K) → 白平衡增益 换算(v21)
 物理模型: 普朗克黑体辐射在 R(600nm)/G(540nm)/B(460nm) 三窄带的功率比,
 6500K(日光) 归一为 1.0x(Q8=256)。低色温(暖光) 降 R 升 B, 高色温相反。
 接口: K 值(单位 100K, 25..100 即 2500K..10000K) -> Q8 增益对。
 实现: 14 锚点线性插值(锚点见 lut_r/lut_b), 一个 9x8 乘法做段内插值,
       流水 2 拍。锚点由普朗克定律离线计算(见 tools/ 注释)。
*****************************************************************/
module wb_kelvin (
    input          I_clk,
    input          I_rst_n,
    input          I_en,           // 高电平期间持续输出换算结果
    input  [6:0]   I_kelvin_hk,    // 色温, 单位 100K (25..100)

    output reg         o_valid,    // 换算结果有效(单拍, 随 I_en 更新)
    output reg  [8:0]  o_gain_r,
    output reg  [8:0]  o_gain_b
);
    /* 14 锚点: index = (K/100 - 25) / 5, 即 2500K=0, 3000K=1 ... 10000K=14
     * (9000K 与 10000K 之间合并为一段) */
    function [8:0] lut_r(input [4:0] i);
        case (i)
            5'd0:  lut_r = 9'd134;   // 2500K
            5'd1:  lut_r = 9'd160;   // 3000K
            5'd2:  lut_r = 9'd181;   // 3500K
            5'd3:  lut_r = 9'd199;   // 4000K
            5'd4:  lut_r = 9'd214;   // 4500K
            5'd5:  lut_r = 9'd227;   // 5000K
            5'd6:  lut_r = 9'd238;   // 5500K
            5'd7:  lut_r = 9'd247;   // 6000K
            5'd8:  lut_r = 9'd256;   // 6500K
            5'd9:  lut_r = 9'd263;   // 7000K
            5'd10: lut_r = 9'd269;   // 7500K
            5'd11: lut_r = 9'd274;   // 8000K
            5'd12: lut_r = 9'd283;   // 9000K(与 10000K 共用段)
            default: lut_r = 9'd291; // 10000K
        endcase
    endfunction
    function [8:0] lut_b(input [4:0] i);
        case (i)
            5'd0:  lut_b = 9'd511;   // 2500K(饱和顶)
            5'd1:  lut_b = 9'd511;   // 3000K(饱和顶)
            5'd2:  lut_b = 9'd467;   // 3500K
            5'd3:  lut_b = 9'd396;   // 4000K
            5'd4:  lut_b = 9'd349;   // 4500K
            5'd5:  lut_b = 9'd315;   // 5000K
            5'd6:  lut_b = 9'd290;   // 5500K
            5'd7:  lut_b = 9'd271;   // 6000K
            5'd8:  lut_b = 9'd256;   // 6500K
            5'd9:  lut_b = 9'd243;   // 7000K
            5'd10: lut_b = 9'd233;   // 7500K
            5'd11: lut_b = 9'd225;   // 8000K
            5'd12: lut_b = 9'd212;   // 9000K
            default: lut_b = 9'd203; // 10000K
        endcase
    endfunction

    /* 输入映射: K/100 = 25..100 -> 锚点 index = (K-25)/5, 段内余量 = (K-25)%5
     * 用乘法代替除法: idx = (K-25) * 14 / 75 (25..100 -> 0..13), 75 段 */
    /* ---- 第一拍: 查锚点与下锚点 ---- */
    reg [4:0]  r_i0, r_i1;
    reg [7:0]  r_frac;             // 段内插值权重 0..74 (段宽 75)
    reg        r_v1;
    reg [8:0]  r_r0, r_r1, r_b0, r_b1;

    wire [7:0] w_k = I_kelvin_hk;
    wire [4:0] w_seg   = ((w_k - 8'd25) * 5'd14) / 8'd75;          // 组合除法: 常数分母综合为乘法
    wire [7:0] w_base  = 8'd25 + w_seg * 8'd5;                     // 段起点 K(百)
    wire [7:0] w_frac  = w_k - w_base;                             // 0..4 (段内百 K)

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_i0 <= 0; r_i1 <= 1; r_frac <= 0; r_v1 <= 0;
            r_r0 <= 0; r_r1 <= 0; r_b0 <= 0; r_b1 <= 0;
        end else begin
            if (I_en) begin
                r_i0  <= w_seg;
                r_i1  <= (w_seg == 5'd13) ? 5'd13 : w_seg + 5'd1;
                r_frac<= {5'd0, w_frac} * 8'd15;               // frac(0..4) -> 0..60/75, 缩放到 0..75 权重
                r_v1  <= 1'b1;
                r_r0  <= lut_r(w_seg);
                r_r1  <= lut_r((w_seg == 5'd13) ? 5'd13 : w_seg + 5'd1);
                r_b0  <= lut_b(w_seg);
                r_b1  <= lut_b((w_seg == 5'd13) ? 5'd13 : w_seg + 5'd1);
            end else begin
                r_v1 <= 1'b0;
            end
        end
    end

    /* ---- 第二拍: 段内线性插值 gain = r0 + (dr * frac >> 8) ----
     * frac 缩放: 段内 0..4 步 x15 -> 0..60, 权重分母 60(段宽 75 的 4/5)
     * 简化: 直接用 frac(0..4) x15 = 0..60, 右移 6 位 => /64, 近似 /60 */
    wire signed [17:0] w_dr  = {1'b0, r_r1} - {1'b0, r_r0};
    wire signed [17:0] w_db  = {1'b0, r_b1} - {1'b0, r_b0};
    wire signed [23:0] w_mul_r = w_dr  * r_frac;
    wire signed [23:0] w_mul_b = w_db  * r_frac;
    wire signed [17:0] w_add_r = {1'b0, r_r0} + (w_mul_r >>> 6);
    wire signed [17:0] w_add_b = {1'b0, r_b0} + (w_mul_b >>> 6);

    // 饱和/限幅: 下限 64(0.25x), 上限 511(Q8 满档)
    wire [8:0] w_g_r = (w_add_r < 0)  ? 9'd64 :
                       (w_add_r > 511) ? 9'd511 : w_add_r[8:0];
    wire [8:0] w_g_b = (w_add_b < 0)  ? 9'd64 :
                       (w_add_b > 511) ? 9'd511 : w_add_b[8:0];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            o_valid <= 1'b0; o_gain_r <= 9'd256; o_gain_b <= 9'd256;
        end else begin
            o_valid  <= r_v1;
            o_gain_r <= w_g_r;
            o_gain_b <= w_g_b;
        end
    end

endmodule
