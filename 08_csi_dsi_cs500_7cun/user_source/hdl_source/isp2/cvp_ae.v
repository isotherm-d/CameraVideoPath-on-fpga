/*
 * ============================================================================
 * cvp_ae —— 自动曝光控制器（RAW 域统计 + 帧尾计算，自研）
 *
 * 位置：cvp_proc 里齿轮箱之后（与 cvp_dpc 并联挂在同一条 1 像素/拍 RAW10 流上，
 *       只读不写，不占用像素通路）。产生的等效曝光经 cvp_top 送 cvp_cam_cfg
 *       写 SC500CS 曝光寄存器（0x3e00/01/02），形成"测量→调参→sensor 生效"闭环。
 *
 * 控制律（tools/ae_convergence_sim.py + --ae-joint 全量仿真已验证，这里整数化）：
 *   eq_new = eq_old × TARGET_MEAN_Q8 / mean_q8      （18% 中灰直接方程）
 *   eq = 等效曝光 = 曝光时间×增益，Q8 定点（256 = 标称 T_NOM = 10ms）
 *   - 死区：|eq_new - eq_old| ≤ eq_old>>4（~6%）保持，防震荡
 *   - 步长限幅：单次更新夹到 [eq_old×0.3125, eq_old×3]
 *   - 过曝紧急回退：饱和像素占比 >20%（5×sat > N）时 eq_new = eq_old×26>>8（~0.1×）
 *     —— 深饱和时均值失真，不受常规限幅
 *   - 范围：[EQ_MIN, EQ_MAX]（EQ_MAX = 帧率约束的曝光上限，v1 不做增益轮换）
 *   - 锁定：连续 3 次落在死区内置 o_locked（给 AWB 联动 gating 预留）
 *
 * 统计：每帧累加 RAW 值（全像素，10bit）与饱和计数（≥SAT_TH）；
 *   帧尾两笔除法（本文件自带 cvp_ae_div 移位减除法，下一帧消隐内完成）：
 *     mean_q8 = acc×256 / N_PIX（Q8 均值）
 *     eq_new  = eq_old × TARGET_Q8 / mean_q8
 *
 * o_req 保持到下一帧首；cvp_cam_cfg 检测 exp/gain 与上次写入不同才发起 I2C
 * （去重，避免逐帧无谓写）。o_eq_q8 同时输出，仿真里喂给传感器曝光模型
 * （cvp_sensor_sim）构成 RTL-in-loop 闭环。
 * ============================================================================
 */
`timescale 1ns/1ps

module cvp_ae #(
    parameter IMG_W    = 1280,
    parameter IMG_H    = 720,
    parameter [15:0]   EQ_NOM     = 16'd256,     // 标称等效曝光（Q8）
    parameter [15:0]   EQ_MIN     = 16'd16,      // 下限（~0.0625x）
    parameter [15:0]   EQ_MAX     = 16'd256,     // v19c: 上限=1.0x(720p30 曝光封顶 998 行, VTS1003)
    parameter [17:0]   TARGET_Q8  = 18'd122880,  // 目标亮度均值（10bit 480 × 256）
    parameter [9:0]    SAT_TH     = 10'd1000,    // 饱和判据（RAW10）
    parameter [15:0]   EXP_CODE_AT_NOM = 16'd1996, // v19c: eq=EQ_NOM(1.0x) 时曝光码 1996 半行=998 行(720p30 半帧; 原 7942 为 720p60 工程标定, 超本配置上限 6 倍致传感器回卷全黑)
    parameter [15:0]   GAIN_CODE  = 16'h0f20     // 增益寄存器值（v1 固定，0x3e08/09）
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    /* 1 像素/拍 RAW10 流（与 cvp_dpc 输入同源并联） */
    input  wire        i_valid,
    input  wire [9:0]  i_raw,
    input  wire        i_frame_start,

    /* 等效曝光输出（仿真里喂给传感器曝光模型；上板可作调试观察） */
    output reg  [15:0] o_eq_q8,
    output reg         o_update,                 // eq 变化时 1 拍
    /* 寄存器写接口（→ cvp_cam_cfg，跨时钟域：值保持一整帧，稳定采样） */
    output reg         o_req,                    // 保持到下一帧首
    output reg  [19:0] o_exp,                    // 曝光寄存器码（0x3e00/01/02 拼装）
    output reg  [15:0] o_gain,                   // 增益寄存器值（0x3e08/09）
    output reg         o_locked,
    output wire [10:0] o_dbg                   // {状态机[2:0], eq_q8[15:8]}
);
    localparam [31:0] N_PIX = IMG_W * IMG_H;
    localparam        AW    = 30;              // 累加器位宽（921600×1023 < 2^30）

    /* ---------------- 1. 逐像素统计 ---------------- */
    reg [AW-1:0] r_acc;
    reg [19:0]   r_sat;
    reg [19:0]   r_pix;

    wire w_sat_hit = (i_raw >= SAT_TH);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_acc <= {AW{1'b0}};
            r_sat <= 20'd0;
            r_pix <= 20'd0;
        end else if (i_frame_start) begin
            /* 帧首：清零并统计本帧第 1 个像素 */
            r_acc <= {{(AW-10){1'b0}}, i_raw};
            r_sat <= {19'd0, w_sat_hit};
            r_pix <= 20'd1;
        end else if (i_valid) begin
            r_acc <= r_acc + {{(AW-10){1'b0}}, i_raw};
            r_sat <= r_sat + {19'd0, w_sat_hit};
            r_pix <= r_pix + 20'd1;
        end
    end

    /* ---------------- 2. 帧尾计算状态机 ---------------- */
    localparam [2:0] S_IDLE = 3'd0, S_D1 = 3'd1, S_D2 = 3'd2, S_APPLY = 3'd3, S_EXP = 3'd4;

    reg [2:0]    r_state;
    reg [AW-1:0] r_acc_d;
    reg [19:0]   r_sat_d;
    reg [15:0]   r_eq;                 // 当前等效曝光（Q8）
    reg [1:0]    r_hold_cnt;           // 连续死区计数（锁定判据）
    reg [19:0]   r_exp_code;           // S_EXP 拍的乘法结果寄存
    reg          r_exp_pend;           // 待写入 o_exp 标志

    /* 除法 1：mean_q8 = acc_d×256 / N_PIX（Q8 均值；×256 由 QW=8 提供） */
    reg         r_d1_start, r_d2_start;   // 单拍启动脉冲（电平会让除法器反复重启）
    wire [37:0] w_num1      = {8'b0, r_acc_d};
    wire        w_d1_start  = r_d1_start;
    wire [17:0] w_mean_q8;
    wire        w_d1_done;

    /* 除法 2：eq_new = eq×TARGET_Q8 / mean_q8 */
    wire [33:0] w_num2     = r_eq * TARGET_Q8;
    wire        w_d2_start = r_d2_start;
    wire [15:0] w_eq_new;
    wire        w_d2_done;

    cvp_ae_div #(.NUM_W(38), .QW(8), .OW(18)) u_div_mean (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_start(w_d1_start), .i_num(w_num1), .i_den({18'd0, N_PIX[19:0]}),
        .o_q(w_mean_q8), .o_done(w_d1_done)
    );
    cvp_ae_div #(.NUM_W(34), .QW(0), .OW(16)) u_div_eq (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_start(w_d2_start), .i_num(w_num2), .i_den({16'd0, w_mean_q8}),
        .o_q(w_eq_new), .o_done(w_d2_done)
    );

    /* ---------------- 3. 判定/限幅/紧急回退 ---------------- */
    wire        w_sat_emerg = ({2'b0, r_sat_d} * 5 > N_PIX);   // 饱和占比 >20%
    wire [15:0] w_emerg_eq  = (r_eq * 8'd26) >> 8;             // ≈0.102x
    wire [15:0] w_step_dn   = {2'b0, r_eq[15:2]} + {3'b0, r_eq[15:4]}; // ≈0.3125x
    wire [16:0] w_step_up   = ({1'b0, r_eq} << 1) + r_eq;      // 3x
    wire [15:0] w_eq_lo     = (w_step_dn < EQ_MIN) ? EQ_MIN : w_step_dn;
    wire [15:0] w_eq_hi     = (w_step_up > {1'b0, EQ_MAX}) ? EQ_MAX : w_step_up[15:0];
    wire [15:0] w_eq_clamp  = (w_eq_new < w_eq_lo) ? w_eq_lo :
                              (w_eq_new > w_eq_hi) ? w_eq_hi : w_eq_new;
    wire [15:0] w_eq_next   = w_sat_emerg ?
                              ((w_emerg_eq < w_eq_lo) ? w_eq_lo : w_emerg_eq) : w_eq_clamp;
    wire [15:0] w_delta     = (w_eq_next > r_eq) ? (w_eq_next - r_eq) : (r_eq - w_eq_next);
    wire        w_in_dz     = (w_delta <= (r_eq >> 4));            // ~6% 死区
    wire        w_apply     = !w_in_dz || w_sat_emerg;             // 死区内保持

    /* 曝光寄存器码 = eq(Q8) × 标定常数 >> 8（eq=EQ_NOM 对应 stock 曝光码）。
     * 显式 32 位中间线：放在 20 位赋值上下文里乘积会先被截断（高位回卷）。 */
    wire [31:0] w_exp_code = o_eq_q8 * EXP_CODE_AT_NOM;

    /* ---------------- 4. 状态寄存与输出 ---------------- */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state    <= S_IDLE;
            r_acc_d    <= {AW{1'b0}};
            r_sat_d    <= 20'd0;
            r_eq       <= EQ_NOM;
            r_hold_cnt <= 2'd0;
            o_eq_q8    <= EQ_NOM;
            o_update   <= 1'b0;
            o_req      <= 1'b0;
            o_exp      <= 20'd0;
            o_gain     <= GAIN_CODE;
            o_locked   <= 1'b0;
            r_exp_code <= 20'd0;
            r_exp_pend <= 1'b0;
        end else begin
            o_update   <= 1'b0;
            r_d1_start <= 1'b0;
            r_d2_start <= 1'b0;
            case (r_state)
                S_IDLE: begin
                    if (r_exp_pend) begin
                        o_exp      <= r_exp_code;
                        r_exp_pend <= 1'b0;
                    end
                    if (i_frame_start) o_req <= 1'b0;   // req 保持一帧后撤
                    /* 帧尾：攒满一帧才触发（r_pix 为上一帧的终值） */
                    if (i_frame_start && (r_pix == N_PIX[19:0])) begin
                        r_acc_d    <= r_acc;
                        r_sat_d    <= r_sat;
                        r_d1_start <= 1'b1;   // 单拍脉冲：启动均值除法
                        r_state    <= S_D1;
                    end
                end
                S_D1: begin
                    if (w_d1_done) begin
                        r_d2_start <= 1'b1;   // 单拍脉冲：启动 eq 除法
                        r_state    <= S_D2;
                    end
                end
                S_D2: if (w_d2_done) r_state <= S_APPLY;
                S_APPLY: begin
                    if (w_apply) begin
                        if (w_eq_next != r_eq) begin
                            r_eq       <= w_eq_next;
                            o_eq_q8    <= w_eq_next;
                            o_update   <= 1'b1;
                            r_hold_cnt <= 2'd0;
                        end else begin
                            r_hold_cnt <= (r_hold_cnt == 2'd3) ? 2'd3 : r_hold_cnt + 2'd1;
                            if (r_hold_cnt == 2'd2) o_locked <= 1'b1;
                        end
                        /* 曝光码单独一拍算：eq×标定常数是 16×16 乘法，
                         * 与 eq_new 的除法输出链串在同一拍实测 -0.3ns（两条 DSP 级联） */
                        r_state <= S_EXP;
                    end else begin
                        r_state <= S_IDLE;
                    end
                end
                S_EXP: begin
                    /* 乘法结果先进一级寄存（DSP 输出直接驱动 o_exp 会差 43ps），
                     * 下一拍再写入 o_exp；o_req 仍保持到下一帧首 */
                    r_exp_code <= w_exp_code[25:8];
                    r_exp_pend <= 1'b1;
                    o_req      <= 1'b1;
                    r_state    <= S_IDLE;
                end
                default: r_state <= S_IDLE;
            endcase
        end
    end

endmodule

/* ---------------- 移位减除法（与 cvp_awb_div 同算法，自包含副本） ----------------
 * 计算 o_q = i_num × 2^QW / i_den，i_start 后 ITER 拍出结果。 */
module cvp_ae_div #(
    parameter NUM_W = 32,        // 分子位宽
    parameter QW    = 8,         // 小数位数
    parameter OW    = 16         // 商位宽
) (
    input  wire             i_clk,
    input  wire             i_rst_n,
    input  wire             i_start,
    input  wire [NUM_W-1:0] i_num,
    input  wire [NUM_W-1:0] i_den,
    output reg  [OW-1:0]    o_q,
    output reg              o_done
);
    localparam DIV_W = NUM_W + QW;
    localparam [6:0] ITER = DIV_W[6:0];

    reg [DIV_W-1:0] r_div;
    reg [NUM_W:0]   r_rem;
    reg [OW-1:0]    r_q;
    reg [6:0]       r_cnt;
    reg             r_busy;

    wire [NUM_W:0]   w_rem_sh = {r_rem[NUM_W-1:0], r_div[DIV_W-1]};
    wire             w_ge     = (w_rem_sh >= {1'b0, i_den});
    wire [NUM_W:0]   w_rem_nx = w_ge ? (w_rem_sh - {1'b0, i_den}) : w_rem_sh;
    wire [DIV_W-1:0] w_div_nx = {r_div[DIV_W-2:0], 1'b0};
    wire [OW-1:0]    w_q_nx   = {r_q[OW-2:0], w_ge};

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_div <= 0; r_rem <= 0; r_q <= 0; r_cnt <= 0; r_busy <= 0;
            o_q <= 0; o_done <= 0;
        end else begin
            o_done <= 1'b0;
            if (i_start) begin
                r_div  <= {i_num, {QW{1'b0}}};
                r_rem  <= 0;
                r_q    <= 0;
                r_cnt  <= 0;
                r_busy <= 1'b1;
            end else if (r_busy) begin
                r_div <= w_div_nx;
                r_rem <= w_rem_nx;
                r_q   <= w_q_nx;
                r_cnt <= r_cnt + 7'd1;
                if (r_cnt == ITER - 7'd1) begin
                    r_busy <= 1'b0;
                    o_q    <= w_q_nx;
                    o_done <= 1'b1;
                end
            end
        end
    end
endmodule
