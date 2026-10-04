/*
 * ============================================================================
 * cvp_awb —— 自动白平衡 AWB v2（三模式互补：FREEZE 守卫 / WP 白点 / GW 灰世界）
 *
 * 框图位置：ISP处理   Demosaic → 【AWB】 → imgproc → 96转128
 *
 * ---------------------------------------------------------------------------
 * 本文件由 awb_lab/rtl/cvp_awb_v2.v（v1.1）按方案 A 并入：
 *   - 模块名/端口与旧灰世界版完全兼容（新增 4 个调试观测口，顶层可不接）；
 *   - 位宽与阈值按 1280x720（921,600 像素/帧）重新标定，见文末参数表；
 *   - 验证结论：awb_lab/REPORT.md（9/9 场景 RTL 与金模型逐位一致，含
 *     FREEZE→WP / WP 保持 / 场景切换 WP→GW 降级 / 均匀场景 FREEZE 保持）。
 *
 * 架构（docs/熵加权AWB落地方案.md §3.5 + §10.8 定稿；A6 三模状态机）：
 *
 *   FREEZE：帧均匀性守卫判定画面无信息 → 增益保持上一帧（不校正）。
 *           守卫量 = Σ|r−pm_r|+|g−pm_g|+|b−pm_b|（pm 为上一帧通道均值 Q8）。
 *           均匀场景 ΣMAD≈噪声底（720p 下约 2M），自然场景约 60~150M，
 *           门限 25M/37.5M 双阈值迟滞分界。
 *   WP    ：自适应百分位白点。上一帧 Y 直方图（32bin）帧尾走查取 87.5% 分位
 *           为亮度门限 y_thr，本帧统计 y>=y_thr 且 40<y<250 的像素（Y 上限
 *           排除过曝），增益 = 白点均值归一 G=1。
 *   GW    ：灰世界 + 高光剔除（与旧版完全一致），作 WP 失效时的回退。
 *
 *   帧尾判决（双阈值迟滞）：
 *     WP 态：N_wp>=WP_EXIT 保持；否则降 GW
 *     GW 态：N_wp>=WP_ENTER 升 WP；ΣMAD>=MAD_TH 保持；否则 FREEZE
 *     FREEZE 态：ΣMAD>=MAD_TH_REC 且 N_wp>=WP_ENTER → 回 WP；
 *               ΣMAD>=MAD_TH_REC 且 N_wp>=N_MIN → 回 GW；否则保持冻结
 *
 * 帧尾时序（本工程 100MHz 写通路，720p60 帧间消隐约 74 万拍，窗口极其宽裕）：
 *   帧 N 最后像素 → +1 拍锁存全部统计终值，并行启动：Y 走查（96 拍）、
 *   均值除法×3（44 拍，更新 pm_* 供下一帧 MAD）、判决（+2 拍）→ 按判决源
 *   启动增益除法×4（48 拍，白点/灰世界各算 R/B 两路并行）→ 帧尾 +60 拍内
 *   全部完成 → 帧 N+1 首像素起使用新状态/新增益/新门限。
 *   白点两帧收敛，与 SC500CS 寄存器 N+2 帧生效节奏一致。
 *
 * 位宽要点（720p 标定，改分辨率必须复核！）：
 *   - 计数（n_wp/n_gw/直方图累计）：921,600 < 2^20 → 20bit；
 *   - 通道和：921,600×255 ≈ 235M < 2^28 → 28bit（WP 和）/32bit（GW 累加器）；
 *   - Y=(R+2G+B)>>2 必须用 10bit 中间量（8bit 会回卷）；
 *   - 均值除法 QW=8（q=acc<<8/den），实例不得预移位——双重移位会让
 *     pm 取到小数垃圾，MAD 守卫整体失效（awb_lab 调试实录 §5 #7）。
 *
 * 除法器：逐位试商（cvp_awb_div），纯移位+减法、不占 DSP，7 路并行，
 *   每帧只在消隐期跑一次（约 100 拍 / 消隐 74 万拍），不影响像素吞吐与帧率。
 * 时序：i_valid → o_valid 固定 2 拍（乘法、右移+饱和），接口与上下游一致。
 * ============================================================================
 */
`timescale 1ns/1ps

/* ---------------------------------------------------------------- 除法子模块 */
/* 逐位试商：q = floor(num * 2^QW / den)，纯移位+减法，ITER 拍出结果。
 * MSB 先出写法，比值>1 也正确；比值超过 2^(OW-QW) 时由外层提前饱和。 */
module cvp_awb_div #(
    parameter NUM_W = 32,        // 分子/分母位宽
    parameter QW    = 16,        // 小数位数
    parameter OW    = 21         // 商位宽
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
    localparam ITER  = DIV_W;

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
                if (r_cnt == ITER-1) begin
                    r_busy <= 1'b0;
                    o_q    <= w_q_nx;
                    o_done <= 1'b1;
                end else r_cnt <= r_cnt + 7'd1;
            end
        end
    end
endmodule
/* ---------------------------------------------------------------------------- */

module cvp_awb #(
    parameter IMG_W    = 1280,
    parameter IMG_H    = 720,
    parameter [9:0]    SUM_LIMIT  = 10'd720,      // GW 高光剔除（沿用旧版）
    parameter [7:0]    WP_Y_MAX   = 8'd250,       // 白点过曝上限
    parameter [7:0]    WP_Y_MIN   = 8'd40,        // 白点暗点下限
    parameter [19:0]   WP_ENTER   = 20'd10000,    // 白点数进 WP（≈1.1% 帧）
    parameter [19:0]   WP_EXIT    = 20'd4000,     // 白点数退 WP（迟滞）
    parameter [19:0]   N_MIN      = 20'd600,      // FREEZE→GW 最少像素数
    parameter [31:0]   MAD_TH     = 32'd25000000, // ΣMAD 冻结门限（720p）
    parameter [31:0]   MAD_TH_REC = 32'd37500000, // ΣMAD 退出冻结（迟滞）
    parameter [20:0]   GAIN_MIN   = 21'd32768,    // Q16 0.5
    parameter [20:0]   GAIN_MAX   = 21'd262144,   // Q16 4.0
    parameter [20:0]   WP_FLAT_TOL = 21'd4600,    // 冷色仲裁容差：WP 增益离 1 的偏差上限（≈±7%）
    parameter [20:0]   GAIN_DEAD   = 21'd1311,    // 增益死区 ≈2%：差小于此保持原值（帧间稳态）
    parameter [20:0]   GAIN_DIRECT = 21'd8192     // 大跳直通 ≈12.5%：场景切换增益立即生效
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    /* 像素输入（1 像素/拍 RGB888） */
    input  wire        i_valid,
    input  wire [23:0] i_rgb,
    input  wire        i_frame_start,

    /* 像素输出（固定 2 拍延迟） */
    output reg         o_valid,
    output reg  [23:0] o_rgb,
    output reg         o_frame_start,

    /* 当前生效的增益（Q16），给调试/上位机看 */
    output reg  [20:0] o_gain_r,
    output reg  [20:0] o_gain_b,
    /* 调试观测（顶层可不接）：模式 / 上一帧白点数 / ΣMAD / 亮度门限 */
    output reg  [1:0]  o_mode,      // 0=FREEZE 1=GW 2=WP
    output reg  [19:0] o_n_wp,
    output reg  [31:0] o_mad,
    output reg  [7:0]  o_y_thr
);

    localparam [1:0] M_FREEZE = 2'd0, M_GW = 2'd1, M_WP = 2'd2;

    /* ==================== 0. 像素坐标（valid 门控） ==================== *
     * 帧首像素占 r_x=0 槽（复位写 1），此后 r_x 恒等于行内像素序号；
     * w_eol/w_eof 屏蔽帧首像素，防止上帧残留坐标在帧首误触发。 */
    reg [11:0] r_x, r_y;
    wire w_eol = i_valid && !i_frame_start && (r_x == IMG_W-1);
    wire w_eof = w_eol && (r_y == IMG_H-1);   // 帧最后像素

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_x <= 12'd0; r_y <= 12'd0;
        end else if (i_valid) begin
            if (i_frame_start) begin
                r_x <= 12'd1; r_y <= 12'd0;
            end else if (w_eol) begin
                r_x <= 12'd0;
                r_y <= (r_y == IMG_H-1) ? 12'd0 : r_y + 12'd1;
            end else r_x <= r_x + 12'd1;
        end
    end

    /* ==================== 1. 亮度 Y ==================== */
    /* 注意：必须用 10 位中间量，否则 8 位加法回卷（R+2G+B 最大 1020） */
    wire [9:0] w_y10 = i_rgb[23:16] + (i_rgb[15:8] << 1) + i_rgb[7:0];
    wire [7:0] w_y   = w_y10[9:2];

    /* ==================== 2. GW 统计（灰世界 + 高光剔除，帧首像素不计） ==== */
    reg [31:0] acc_r, acc_g, acc_b;
    reg  [19:0] n_gw;
    wire [9:0] w_pix_sum = i_rgb[23:16] + i_rgb[15:8] + i_rgb[7:0];
    wire       w_gw_en   = i_valid && !i_frame_start && (w_pix_sum < SUM_LIMIT);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            acc_r <= 32'd1; acc_g <= 32'd1; acc_b <= 32'd1;
        end else if (i_valid && i_frame_start) begin
            acc_r <= 32'd1; acc_g <= 32'd1; acc_b <= 32'd1; n_gw <= 20'd0;
        end else if (w_gw_en) begin
            acc_r <= acc_r + {24'd0, i_rgb[23:16]};
            acc_g <= acc_g + {24'd0, i_rgb[15:8]};
            acc_b <= acc_b + {24'd0, i_rgb[7:0]};
            n_gw  <= n_gw + 20'd1;
        end
    end

    /* ==================== 3. WP 白点统计（门限 = 上一帧走查结果） ========== */
    reg  [7:0]  r_y_thr;
    reg  [19:0] n_wp;
    reg  [27:0] s_r_wp, s_g_wp, s_b_wp;
    wire        w_wp_en = i_valid && !i_frame_start &&
                         (w_y >= r_y_thr) && (w_y < WP_Y_MAX) && (w_y > WP_Y_MIN);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            n_wp <= 20'd0; s_r_wp <= 28'd0; s_g_wp <= 28'd0; s_b_wp <= 28'd0;
        end else if (i_valid && i_frame_start) begin
            n_wp <= 20'd0; s_r_wp <= 28'd0; s_g_wp <= 28'd0; s_b_wp <= 28'd0;
        end else if (w_wp_en) begin
            n_wp   <= n_wp + 20'd1;
            s_r_wp <= s_r_wp + {20'd0, i_rgb[23:16]};
            s_g_wp <= s_g_wp + {20'd0, i_rgb[15:8]};
            s_b_wp <= s_b_wp + {20'd0, i_rgb[7:0]};
        end
    end

    /* ==================== 4. 均匀性守卫：Σ|ch − 上一帧均值| ================ *
     * pm_* 为上一帧通道均值（Q8）。均匀场景 ΣMAD≈噪声底，自然场景大。 */
    reg  [15:0] pm_r, pm_g, pm_b;                 // 上一帧均值 Q8
    reg  [31:0] mad_acc;                          // Σ|·|（三通道，原始计数）
    wire [7:0]  w_dr = (i_rgb[23:16] > pm_r[15:8]) ? (i_rgb[23:16] - pm_r[15:8])
                                                   : (pm_r[15:8] - i_rgb[23:16]);
    wire [7:0]  w_dg = (i_rgb[15:8] > pm_g[15:8]) ? (i_rgb[15:8] - pm_g[15:8])
                                                  : (pm_g[15:8] - i_rgb[15:8]);
    wire [7:0]  w_db = (i_rgb[7:0]  > pm_b[15:8]) ? (i_rgb[7:0]  - pm_b[15:8])
                                                  : (pm_b[15:8]  - i_rgb[7:0]);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            mad_acc <= 32'd0;    /* pm_* 的复位在均值更新块（唯一驱动源，勿在此重复） */
        end else if (i_valid && i_frame_start) begin
            mad_acc <= 32'd0;
        end else if (i_valid) begin
            mad_acc <= mad_acc + {24'd0, w_dr} + {24'd0, w_dg} + {24'd0, w_db};
        end
    end

    /* ==================== 5. Y 直方图（32bin × 2 组乒乓，单写口） =========== *
     * 帧 N 用一组；帧尾空隙内走查（求门限）并清零；帧 N+1 用另一组。
     * 写口必须唯一：像素累积（帧内 valid 期）与走查清零（帧尾空隙）时间互斥，
     * 走查清零优先；拆成两个进程写会触发综合 HDL-8007 多驱动错误。 */
    localparam [1:0] W_IDLE = 2'd0, W_TOT = 2'd1, W_THR = 2'd2, W_CLR = 2'd3;
    reg [1:0]  r_wst;
    reg [5:0]  r_wbin;
    reg [19:0] r_wtot, r_wcum;   // 20bit：帧像素数最大 921,600
    reg        r_wfound;

    reg [19:0] yhist [0:1][0:31];
    reg        r_yset;
    integer    yw;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            for (yw = 0; yw < 32; yw = yw + 1) begin
                yhist[0][yw] <= 20'd0;
                yhist[1][yw] <= 20'd0;
            end
        end else if (r_wst == W_THR || r_wst == W_CLR) begin
            yhist[r_yset][r_wbin] <= 20'd0;      // 走查边走边清
        end else if (i_valid && !i_frame_start) begin
            yhist[r_yset][w_y[7:3]] <= yhist[r_yset][w_y[7:3]] + 20'd1;
        end
    end

    /* ==================== 6. 帧尾 Y 走查（TOT→THR→CLR，96 拍） ============= */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_wst <= W_IDLE; r_wbin <= 6'd0; r_wtot <= 20'd0; r_wcum <= 20'd0;
            r_wfound <= 1'b0; r_y_thr <= 8'd200; r_yset <= 1'b0;
        end else begin
            case (r_wst)
                W_IDLE: if (w_eof) begin
                    r_wst <= W_TOT; r_wbin <= 6'd0;
                    r_wtot <= 20'd0; r_wcum <= 20'd0; r_wfound <= 1'b0;
                end
                W_TOT: begin
                    r_wtot <= r_wtot + {1'b0, yhist[r_yset][r_wbin]};
                    r_wbin <= r_wbin + 6'd1;
                    if (r_wbin == 6'd31) begin
                        r_wst <= W_THR; r_wbin <= 6'd0; r_wcum <= 20'd0;
                    end
                end
                W_THR: begin
                    /* 累计（含当前 bin）先到 87.5% 分位的 bin 即门限（只锁存一次） */
                    if (!r_wfound &&
                        (r_wcum + {1'b0, yhist[r_yset][r_wbin]}) >=
                        (r_wtot - (r_wtot >> 3)) && (r_wtot > 20'd100)) begin
                        r_wfound <= 1'b1;
                        r_y_thr  <= {r_wbin[4:0], 3'd0};   // bin*8（5bit bin + 3bit 0）
                    end
                    r_wcum <= r_wcum + {1'b0, yhist[r_yset][r_wbin]};
                    r_wbin <= r_wbin + 6'd1;
                    if (r_wbin == 6'd31) begin
                        r_wst <= W_CLR; r_wbin <= 6'd0;
                    end
                end
                W_CLR: begin
                    r_wbin <= r_wbin + 6'd1;
                    if (r_wbin == 6'd31) begin
                        r_wst <= W_IDLE;
                        r_yset <= ~r_yset;               // 下一帧换组
                    end
                end
                default: r_wst <= W_IDLE;
            endcase
        end
    end

    /* ==================== 7. 帧尾判决与除法（并行除法，消隐期内完成） ====== */
    /* 帧尾流水：eof(T) → T+1 锁存统计终值（含末像素贡献）+ 启动均值除法/Y走查
     * → T+2 三模判决（读锁存值）→ T+3 启动增益除法（按判决选源）→ 增益/模式
     * 在除法完成时锁存。全部在帧间消隐内完成。 */
    reg        r_eof1, r_eof2, r_eof3;
    reg [19:0] d_n_wp;
    reg [31:0] d_mad;
    reg [27:0] d_sr_wp, d_sg_wp, d_sb_wp;         // WP 白点通道和（帧终值）
    reg [31:0] d_ar, d_ag, d_ab;                  // GW 通道和（帧终值）
    reg [1:0]  r_next;
    reg        r_src_wp, r_src_gw;                // 本帧增益源（互斥）
    reg        r_arb;                             // 冷色仲裁迟滞锁存（v1.3）
    /* 增益锁存两级流水：done 拍算目标（仲裁+限幅），下一拍做平滑——
     * 把仲裁比较/乘法与平滑加减拆开，避免 100MHz 下 o_gain 组合链违例 */
    reg        r_upd, r_arb_dec, r_swp_dec;
    reg [20:0] r_t_r, r_t_b;
    reg [1:0]  r_next_d1;
    wire [20:0] q_wpr, q_wpb, q_gwr, q_gwb;
    wire [20:0] q_mr, q_mg, q_mb;
    wire        done_mr, done_mg, done_mb;
    wire        done_wpr, done_wpb, done_gwr, done_gwb;
    reg         r_mdiv_start, r_gdiv_start;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_eof1 <= 1'b0; r_eof2 <= 1'b0; r_eof3 <= 1'b0;
            d_n_wp <= 20'd0; d_mad <= 32'd0;
            d_sr_wp <= 28'd0; d_sg_wp <= 28'd0; d_sb_wp <= 28'd0;
            d_ar <= 32'd1; d_ag <= 32'd1; d_ab <= 32'd1;
            r_mdiv_start <= 1'b0; r_gdiv_start <= 1'b0;
        end else begin
            r_eof1       <= w_eof;
            r_eof2       <= r_eof1;
            r_eof3       <= r_eof2;
            r_mdiv_start <= r_eof1;
            r_gdiv_start <= r_eof3;
            if (r_eof1) begin
                d_n_wp  <= n_wp;
                d_mad   <= mad_acc;
                d_sr_wp <= s_r_wp; d_sg_wp <= s_g_wp; d_sb_wp <= s_b_wp;
                d_ar    <= acc_r;  d_ag    <= acc_g;  d_ab    <= acc_b;
            end
        end
    end

    /* 均值除法 ×3（并行）：pm = acc*256 / n_gw（Q8，供下一帧 MAD 用）。
     * QW=8 内部自带 <<8，i_num 直接喂累加和，不能再预移位（否则变 Q16，
     * 取低 16 位即小数垃圾）。26bit+ 累加和 ×256 需 36bit 除法位宽。 */
    cvp_awb_div #(.NUM_W(36), .QW(8), .OW(21)) u_div_mr (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_mdiv_start),
        .i_num({8'd0, d_ar[27:0]}), .i_den({16'd0, n_gw}), .o_q(q_mr), .o_done(done_mr)
    );
    cvp_awb_div #(.NUM_W(36), .QW(8), .OW(21)) u_div_mg (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_mdiv_start),
        .i_num({8'd0, d_ag[27:0]}), .i_den({16'd0, n_gw}), .o_q(q_mg), .o_done(done_mg)
    );
    cvp_awb_div #(.NUM_W(36), .QW(8), .OW(21)) u_div_mb (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_mdiv_start),
        .i_num({8'd0, d_ab[27:0]}), .i_den({16'd0, n_gw}), .o_q(q_mb), .o_done(done_mb)
    );

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            pm_r <= 16'd32768; pm_g <= 16'd32768; pm_b <= 16'd32768;
        end else begin
            if (done_mr && n_gw > 20'd100) pm_r <= q_mr[15:0];
            if (done_mg && n_gw > 20'd100) pm_g <= q_mg[15:0];
            if (done_mb && n_gw > 20'd100) pm_b <= q_mb[15:0];
        end
    end

    /* 增益除法 ×4（并行）：白点集与灰世界集各算 R/B 两路（Q16） */
    cvp_awb_div #(.NUM_W(32), .QW(16), .OW(21)) u_div_wpr (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_gdiv_start),
        .i_num({4'd0, d_sg_wp}), .i_den({4'd0, d_sr_wp}), .o_q(q_wpr), .o_done(done_wpr)
    );
    cvp_awb_div #(.NUM_W(32), .QW(16), .OW(21)) u_div_wpb (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_gdiv_start),
        .i_num({4'd0, d_sg_wp}), .i_den({4'd0, d_sb_wp}), .o_q(q_wpb), .o_done(done_wpb)
    );
    cvp_awb_div #(.NUM_W(32), .QW(16), .OW(21)) u_div_gwr (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_gdiv_start),
        .i_num({4'd0, d_ag[27:0]}), .i_den({4'd0, d_ar[27:0]}), .o_q(q_gwr), .o_done(done_gwr)
    );
    cvp_awb_div #(.NUM_W(32), .QW(16), .OW(21)) u_div_gwb (
        .i_clk(i_clk), .i_rst_n(i_rst_n), .i_start(r_gdiv_start),
        .i_num({4'd0, d_ag[27:0]}), .i_den({4'd0, d_ab[27:0]}), .o_q(q_gwb), .o_done(done_gwb)
    );

    /* 增益>16 倍预判（避免 21 位商回绕，与金模型 num>den<<4 → 上限一致） */
    wire ovf_wpr = ({6'd0, d_sg_wp} > ({6'd0, d_sr_wp} << 4));
    wire ovf_wpb = ({6'd0, d_sg_wp} > ({6'd0, d_sb_wp} << 4));
    wire ovf_gwr = ({6'd0, d_ag} > ({6'd0, d_ar} << 4));
    wire ovf_gwb = ({6'd0, d_ag} > ({6'd0, d_ab} << 4));

    /* —— 冷色场景仲裁（v1.2）：白点法失效兜底 ——
     * 场景中存在"本就中性"的亮物体（如被拍照设备自己拉白的纸盒/白纸）时，
     * WP 白点增益≈1（白点说没偏色），但全帧通道均值明显偏离中性
     * （max/min ≥ 5/4，灰世界统计说偏了）。此时改用灰世界增益把帧均值
     * 拉中性，o_mode 同步置 GW。v1.3 增加双阈值迟滞：进入用 1.25、
     * 退出用 1.15（20/23 倍比较），边界场景不再 WP/GW 来回泵动。 */
    wire [20:0] w_dev_r = (q_wpr > 21'd65536) ? (q_wpr - 21'd65536) : (21'd65536 - q_wpr);
    wire [20:0] w_dev_b = (q_wpb > 21'd65536) ? (q_wpb - 21'd65536) : (21'd65536 - q_wpb);
    wire        w_wp_flat = (w_dev_r <= WP_FLAT_TOL) && (w_dev_b <= WP_FLAT_TOL);
    wire [15:0] w_pm_max = (pm_r > pm_g) ? ((pm_r > pm_b) ? pm_r : pm_b)
                                         : ((pm_g > pm_b) ? pm_g : pm_b);
    wire [15:0] w_pm_min = (pm_r < pm_g) ? ((pm_r < pm_b) ? pm_r : pm_b)
                                         : ((pm_g < pm_b) ? pm_g : pm_b);
    wire        w_tinted_eng = (w_pm_min >= 16'd320) &&   // 进入：≥1.25，均值下限排暗场
                               (({w_pm_max, 2'd0}) >= ({w_pm_min, 2'd0} + {w_pm_min, 2'd0} + w_pm_min));
    wire        w_tinted_rel = (w_pm_min >= 16'd256) &&   // 退出：≥1.15（迟滞）
                               (({w_pm_max, 2'd0} * 5'd20) >= ({w_pm_min, 2'd0} * 5'd23));
    wire        w_arb_next = w_wp_flat && (r_arb ? w_tinted_rel : w_tinted_eng);

    /* —— 增益时域平滑（v1.3）：相似场景多帧稳定性的关键 ——
     * 三段式：|Δ|<死区(2%) 保持原值（滤统计噪声抖动）；
     *         死区≤|Δ|<12.5% 每帧走 Δ/2（一阶惯性，平滑收敛）；
     *         |Δ|≥12.5% 直接生效（真场景切换，拖泥带水更难看）。
     * 统计取自增益前级（开环），平滑只作用于增益本身，不会自激。 */
    function [20:0] smooth_gain;
        input [20:0] old_g;
        input [20:0] tgt;
        reg [21:0] d22, a, step;
        reg neg;
        begin
            /* 全程无符号显式实现：signed 移位在部分工具/表达式上下文中会退化成逻辑移位 */
            d22 = {1'b0, tgt} - {1'b0, old_g};          // Δ 的 22bit 补码
            neg = d22[21];
            a = neg ? (~d22 + 1) : d22;                 // |Δ|
            if (a < GAIN_DEAD)
                smooth_gain = old_g;                    // 死区：保持
            else if (a >= GAIN_DIRECT)
                smooth_gain = tgt;                      // 大跳：直通
            else begin
                step = a >> 2;                          // α=1/4 惯性
                smooth_gain = neg ? (old_g - step) : (old_g + step);
            end                                         // Δ≤old_g，不会下溢/上溢
        end
    endfunction

    function [20:0] clamp_gain;
        input [20:0] q;
        begin
            if (q < GAIN_MIN)      clamp_gain = GAIN_MIN;
            else if (q > GAIN_MAX) clamp_gain = GAIN_MAX;
            else                   clamp_gain = q;
        end
    endfunction

    /* 三模判决 + 增益/状态生效 */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_next <= M_FREEZE; r_src_wp <= 1'b0; r_src_gw <= 1'b0; r_arb <= 1'b0;
            o_gain_r <= 21'd65536; o_gain_b <= 21'd65536;
            o_mode <= M_FREEZE;
        end else if (r_eof2) begin
            /* 判决（eof+2 拍：d_n_wp/d_mad 为上一帧统计终值，已于 eof+1 锁存） */
            if (o_mode == M_WP) begin
                if (d_n_wp >= WP_EXIT) begin
                    r_next <= M_WP;  r_src_wp <= 1'b1; r_src_gw <= 1'b0;
                end else begin
                    r_next <= M_GW;  r_src_wp <= 1'b0; r_src_gw <= 1'b1;
                end
            end else if (o_mode == M_GW) begin
                if (d_n_wp >= WP_ENTER) begin
                    r_next <= M_WP;  r_src_wp <= 1'b1; r_src_gw <= 1'b0;
                end else if (d_mad >= MAD_TH) begin
                    r_next <= M_GW;  r_src_wp <= 1'b0; r_src_gw <= 1'b1;
                end else begin
                    r_next <= M_FREEZE; r_src_wp <= 1'b0; r_src_gw <= 1'b0;
                end
            end else begin /* M_FREEZE */
                if (d_mad >= MAD_TH_REC && d_n_wp >= WP_ENTER) begin
                    r_next <= M_WP;  r_src_wp <= 1'b1; r_src_gw <= 1'b0;
                end else if (d_mad >= MAD_TH_REC && d_n_wp >= N_MIN) begin
                    r_next <= M_GW;  r_src_wp <= 1'b0; r_src_gw <= 1'b1;
                end else begin
                    r_next <= M_FREEZE; r_src_wp <= 1'b0; r_src_gw <= 1'b0;
                end
            end
        end else begin
            /* 第一级：除法完成拍——算仲裁与限幅后的增益目标 */
            r_upd <= (r_src_wp && done_wpr) || (r_src_gw && done_gwr);
            if ((r_src_wp && done_wpr) || (r_src_gw && done_gwr)) begin
                r_swp_dec <= r_src_wp;
                r_next_d1 <= r_next;
                r_arb_dec <= w_arb_next;
                r_arb     <= w_arb_next;
                r_t_r <= r_src_wp ? (w_arb_next ? (ovf_gwr ? GAIN_MAX : clamp_gain(q_gwr))
                                                : (ovf_wpr ? GAIN_MAX : clamp_gain(q_wpr)))
                                 : (ovf_gwr ? GAIN_MAX : clamp_gain(q_gwr));
                r_t_b <= r_src_wp ? (w_arb_next ? (ovf_gwb ? GAIN_MAX : clamp_gain(q_gwb))
                                                : (ovf_wpb ? GAIN_MAX : clamp_gain(q_wpb)))
                                 : (ovf_gwb ? GAIN_MAX : clamp_gain(q_gwb));
            end
            /* 第二级：时域平滑（死区/惯性/大跳直通）+ 模式生效 */
            if (r_upd) begin
                o_gain_r <= smooth_gain(o_gain_r, r_t_r);
                o_gain_b <= smooth_gain(o_gain_b, r_t_b);
                o_mode   <= r_swp_dec ? (r_arb_dec ? M_GW : r_next_d1) : r_next_d1;
            end
            if (r_gdiv_start && !r_src_wp && !r_src_gw)
                o_mode <= M_FREEZE;            /* 判决冻结：保持增益，状态置冻结 */
        end
    end

    /* 调试观测输出（直通帧终值锁存） */
    always @(*) begin
        o_n_wp  = d_n_wp;
        o_mad   = d_mad;
        o_y_thr = r_y_thr;
    end

    /* ==================== 8. 输出像素通路（与旧版一致） ==================== */
    reg [28:0] p_r, p_b;
    reg [7:0]  p_g;
    reg        v1, fs1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            p_r <= 29'd0; p_g <= 8'd0; p_b <= 29'd0;
            v1  <= 1'b0;  fs1 <= 1'b0;
        end else begin
            p_r <= i_rgb[23:16] * o_gain_r;
            p_g <= i_rgb[15:8];
            p_b <= i_rgb[7:0]   * o_gain_b;
            v1  <= i_valid;
            fs1 <= i_frame_start;
        end
    end

    function [7:0] sat8;
        input [12:0] x;
        begin
            sat8 = (x > 13'd255) ? 8'd255 : x[7:0];
        end
    endfunction

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rgb <= 24'd0; o_valid <= 1'b0; o_frame_start <= 1'b0;
        end else begin
            o_rgb         <= { sat8(p_r[28:16]), p_g, sat8(p_b[28:16]) };
            o_valid       <= v1;
            o_frame_start <= fs1;
        end
    end

endmodule
