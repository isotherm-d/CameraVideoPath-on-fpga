`timescale 1ns / 1ns
/*****************************************************************
 ae_mux —— 自动/手动曝光选择 + 码制转换(v19)
 通路: cvp_ae.o_exp(曝光寄存器码, 半行) / o_gain(0x3e08/09 拼装)
       -> [自动] 除 16 得 I_AE(uics500regAE 把 I_AE 铺回寄存器, x16 还原)
       -> 二选一 -> uicfgcs500.I_ae/I_ag (I2C 写通路, 已验证)
 i_mode: 0=手动(ae_set 按键值) 1=自动(cvp_ae 闭环)
 o_req: 自动模式转发 cvp_ae 的 o_req(保持一帧的电平, 跨到 24M 域安全)
*****************************************************************/
module ae_mux (
    input          I_clk,          // 100M(与 ae_set/cvp_ae 同域)
    input          I_rst_n,
    input          I_mode_auto,    // 1=自动曝光

    /* 手动通道(ae_set 输出) */
    input          I_man_req,
    input  [15:0]  I_man_ae,
    input  [15:0]  I_man_ag,

    /* 自动通道(cvp_ae 输出) */
    input          I_auto_req,     // 保持到下一帧首的电平
    input  [19:0]  I_auto_exp,     // 曝光寄存器码(半行)
    input  [15:0]  I_auto_gain,    // 3e08/09 拼装值

    /* 到 uicfgcs500 */
    output reg         O_ae_req,
    output reg  [15:0] O_ae,
    output reg  [15:0] O_ag
);
    // 曝光寄存器码(半行) -> I_AE: I_AE = 码 >> 4 (uics500regAE 铺位后 x16 还原)
    wire [15:0] w_auto_ae = I_auto_exp[19:4];

    // cvp_ae 的 o_req 是 100M 电平(保持约一帧 33ms), 打两拍进 24M 域时
    // 由 uicfgcs500 电平采样即可; 这里在 100M 侧把电平收窄为单帧一次事件
    // 已由 cvp_ae 内部保证(帧尾一次), 直接寄存转发。
    /* req 脉冲化: cvp_ae 的 o_req 是"保持到下一帧首"的长电平, 而 uicfgcs500
     * 的写表状态机要求 I_ae_req 为短脉冲(电平持续高会持续清 reg_index,
     * AE 表永远写不进 -> 曝光不变)。边沿检测 + 展宽 1ms(24M 采样域可靠)。 */
    reg        r_auto_d1, r_auto_d2;
    reg [16:0] r_pulse;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_ae_req <= 1'b0;
            O_ae     <= 16'd1400;   // 默认值与 ae_set 一致语义(720p30, 700 行)
            O_ag     <= 16'd80;     // 增益档 80(表索引 64 = 0x0F20 = 4.0x)
            r_auto_d1 <= 1'b0;
            r_auto_d2 <= 1'b0;
            r_pulse   <= 17'd0;
        end else begin
            r_auto_d1 <= I_auto_req;
            r_auto_d2 <= r_auto_d1;

            if (I_mode_auto) begin
                O_ae <= w_auto_ae;
                O_ag <= I_auto_gain;
                // 上升沿检测: cvp_ae 每帧算完拉高一次
                if (r_auto_d1 && !r_auto_d2)
                    r_pulse <= 17'd100000;            // 1ms @100M
                else if (r_pulse != 17'd0)
                    r_pulse <= r_pulse - 17'd1;
                O_ae_req <= (r_pulse != 17'd0);
            end else begin
                r_pulse <= 17'd0;
                O_ae     <= I_man_ae;
                O_ag     <= I_man_ag;
                O_ae_req <= I_man_req;
            end
        end
    end
endmodule
