/*
 * ============================================================================
 * cvp_proc —— RAW10 解包成像素流 + 3x3 双线性彩色重建（自研）
 *
 * 输入：cvp_rx_pipeline 的 4 像素/拍 RAW10 组（40bit，低 10bit=像素0）
 * 输出：1 像素/拍 RGB888（100MHz），供后续 AWB / 算法 / 帧缓存使用。
 *
 * 本模块分三步：
 *   1) 齿轮箱（gearbox）：把 4 像素/拍的 40bit 组展开成 1 像素/拍的 10bit 流。
 *   2) 坏点检测/矫正：交给 cvp_dpc（RAW 域 3x3 同色判据，命中才用同色邻居
 *      中位数替换，其余直通）。必须在彩色重建之前修 —— 坏点经过 demosaic
 *      会扩散成 5 像素的十字彩色斑。固定 4 拍延迟（判据/矫正两级流水）。
 *   3) 彩色重建：交给 cvp_demosaic（3x3 双线性，BGGR），固定 3 拍延迟。
 *      —— 原来那段“2 行近似”重建结构上就是坏的（探针 TB 扫遍所有对齐都对不上、
 *         色块自检饱和色会互换色平面），已整体替换。
 *
 * 算法模式 i_mode（保留的像素级算法；在 cvp_top 里现在固定送 0，
 * 因为 3x3 的算法（高斯/中值/真 Sobel）已经搬到 imgproc_top）：
 *   0 = 原摄像头输出（彩色重建结果直通）
 *   1 = 灰度：Y = (R + 2G + B) >> 2
 *   2 = 二值化：Y >= 128 为白，否则为黑
 *   3 = 灰度（原“简化边缘”已由 imgproc 的真 Sobel 取代，这里保留为灰度）
 *   4 = 反色
 *   5 = 红蓝通道交换（伪彩）
 *   6 = 亮度增强（每个通道 +32，饱和到 255）
 *
 * Bayer 相位：BGGR，即
 *   row even: B G B G ...
 *   row odd : G R G R ...
 * ============================================================================
 */
module cvp_proc #(
    parameter IMG_W = 1024,
    parameter IMG_H = 600,
    parameter [10:0] EDGE_THRESH = 11'd60,  // 保留参数（兼容旧例化；当前模式里未使用）

    // ---- 曝光/白平衡参数(传感器寄存器值, 上电经 ae_cmd 通路写入 SC500CS) ----
    parameter [15:0] AE_EXP_CODE = 16'd1700,  // 曝光寄存器码(半行)。VTS=1003 理论上限 1996, 但实测贴近满帧时传感器读出窗
                                              // 相对帧同步偏移数行, 顶/底部出现错位带(1940 仍复现) —— 收到 1700(850 行, 裕量 153)
    parameter [15:0] AE_GAIN_IDX = 16'd108,   // 模拟增益档(档=表索引+16, 合法 16..143; 108 -> 0x0F3C = 7.5x, 补偿曝光下调, 仍属已验证 0x0F 组)
    parameter [8:0]  WB_GAIN_R   = 9'd438,    // 白平衡 R 增益 Q8(438≈1.71x, 白纸标定)
    parameter [8:0]  WB_GAIN_G   = 9'd386,    // 白平衡 G 增益 Q8(386≈1.51x 数字补光)
    parameter [8:0]  WB_GAIN_B   = 9'd371,    // 白平衡 B 增益 Q8(371≈1.45x)
    parameter        WB_SWAP_RB  = 1'b0       // R/B 通道互换(色序错时置 1)
) (
    input  wire         i_clk,
    input  wire         i_rst_n,
    input  wire [2:0]   i_mode,
    input  wire         i_cam_cfg_done,

    /* v23: 运行时曝光命令(cvp_cmd_rx 输出, 与 i_clk 同为 100M 域) */
    input  wire [15:0]  i_cmd_ae,      // 网络曝光码(半行)
    input  wire         i_cmd_ae_wr,   // 单拍: 曝光命令到达(与 i_cmd_ae 同拍有效)

    input  wire         i_grp_valid,
    input  wire [39:0]  i_grp_data,
    input  wire         i_grp_frame_start,
    input  wire         i_grp_line_last,

    output reg          o_pix_valid,
    output reg  [23:0]  o_pix_rgb,
    output reg          o_pix_frame_start,
    output reg          o_pix_line_last,

    /* AE/AWB 上电参数写入通路：把本模块的曝光/增益参数经 uicfgcs500
     * 写入 SC500CS(传感器主表配置完成后写一次)。值 = 参数 AE_EXP_CODE/AE_GAIN_IDX。
     * 白平衡在 color_correct(数字域)完成, 与传感器增益独立。 */
    output wire         o_ae_req,
    output wire [15:0]  o_ae,
    output wire [15:0]  o_ag
);

    /* ================= 0. AE/AWB 参数通路(上电 + v23 网络运行时) =================
     * cam_cfg_done 后保持 o_ae_req 高 1023 拍(10us), 顶层 uicfgcs500 采样后
     * 启动 AE 表写入。v23: o_ae 由常量改为寄存器 —— 收到网络曝光命令时
     * 锁存新值(钳位 62..1800)并重发 req, uicfgcs500 见 req 重写传感器
     * 0x3e00/01/02(其状态机的 I_ae_req 分支即重触发入口)。
     * 注: r_ae_val 组合进入 24M 域 uicfgcs500, 但只在命令拍更新(人为速率),
     * I2C 写期间(~2ms)保持稳定, 免握手中继。 */
    reg [9:0]  r_ae_req_cnt = 10'd1023;
    reg        r_cfg_done_s1;
    reg        r_cfg_done_d;
    reg [15:0] r_ae_val;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_ae_req_cnt <= 10'd1023;
            r_cfg_done_s1 <= 1'b0;
            r_cfg_done_d <= 1'b0;
            r_ae_val     <= AE_EXP_CODE;
        end else begin
            // Synchronize the 24 MHz configuration result into the 100 MHz domain.
            r_cfg_done_s1 <= i_cam_cfg_done;
            r_cfg_done_d <= r_cfg_done_s1;
            if (i_cmd_ae_wr && r_cfg_done_d) begin
                r_ae_val     <= (i_cmd_ae < 16'd62)   ? 16'd62   :
                                (i_cmd_ae > 16'd1800) ? 16'd1800 : i_cmd_ae;   // 上限收紧: >=900 行读出窗偏移, 顶/底错位带
                r_ae_req_cnt <= 10'd1023;    // 重发请求(若正在倒数则顺延, 无害)
            end else if (r_cfg_done_d && r_ae_req_cnt != 10'd0)
                r_ae_req_cnt <= r_ae_req_cnt - 10'd1;
        end
    end
    // The startup count is pending work, not permission to interrupt base setup.
    // Asserting AE before cfg_done holds uicfgcs500 at register index zero.
    assign o_ae_req = r_cfg_done_d && (r_ae_req_cnt != 10'd0);
    assign o_ae     = r_ae_val;
    assign o_ag     = AE_GAIN_IDX;

    /* ================= 1. 齿轮箱：4 像素/拍 → 1 像素/拍 ================= */
    reg [9:0]  r_p0, r_p1, r_p2, r_p3;
    reg [2:0]  r_pix_cnt;      // 当前组里还剩几个像素没弹出
    reg [1:0]  r_pop_idx;      // 下一个弹出的像素序号
    reg        r_fs_lat, r_last_lat;
    wire [9:0] w_pix_sel = (r_pop_idx == 2'd0) ? r_p0 :
                           (r_pop_idx == 2'd1) ? r_p1 :
                           (r_pop_idx == 2'd2) ? r_p2 : r_p3;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_p0 <= 10'd0; r_p1 <= 10'd0; r_p2 <= 10'd0; r_p3 <= 10'd0;
            r_pix_cnt <= 3'd0;
            r_pop_idx <= 2'd0;
            r_fs_lat  <= 1'b0;
            r_last_lat<= 1'b0;
        end else begin
            if (i_grp_valid && r_pix_cnt == 3'd0) begin
                /* 取出一组 4 像素；本设计组速率远低于 100MHz，4 拍内必弹空 */
                r_p0      <= i_grp_data[9:0];
                r_p1      <= i_grp_data[19:10];
                r_p2      <= i_grp_data[29:20];
                r_p3      <= i_grp_data[39:30];
                r_pix_cnt <= 3'd4;
                r_pop_idx <= 2'd0;
                r_fs_lat  <= i_grp_frame_start;
                r_last_lat<= i_grp_line_last;
            end else if (r_pix_cnt != 3'd0) begin
                r_pix_cnt <= r_pix_cnt - 3'd1;
                r_pop_idx <= r_pop_idx + 2'd1;
            end
        end
    end

    wire w_pix_step = (r_pix_cnt != 3'd0);
    wire w_pix_fs   = w_pix_step && (r_pop_idx == 2'd0) && r_fs_lat;
    wire w_pix_last = w_pix_step && (r_pop_idx == 2'd3) && r_last_lat;

    /* ================= 2. 坏点检测/矫正：RAW 域 3x3 同色 DPC ================= */
    wire        w_dpc_valid, w_dpc_fs;
    wire [9:0]  w_dpc_raw;

    cvp_dpc #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H)
    ) u_dpc (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_pix_step),
        .i_raw         (w_pix_sel),
        .i_frame_start (w_pix_fs),
        .o_valid       (w_dpc_valid),
        .o_raw         (w_dpc_raw),
        .o_frame_start (w_dpc_fs)
    );


    /* ================= 3. 彩色重建：3x3 双线性（BGGR） ================= */
    wire        w_dem_valid, w_dem_fs;
    wire [23:0] w_dem_rgb;

    cvp_demosaic #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H)
    ) u_demosaic (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_valid       (w_dpc_valid),
        .i_raw         (w_dpc_raw),
        .i_frame_start (w_dpc_fs),
        .o_valid       (w_dem_valid),
        .o_rgb         (w_dem_rgb),
        .o_frame_start (w_dem_fs)
    );

    /* ================= 4. 像素级算法模式（保留） ================= */
    wire [7:0] w_r = w_dem_rgb[23:16];
    wire [7:0] w_g = w_dem_rgb[15:8];
    wire [7:0] w_b = w_dem_rgb[7:0];

    wire [9:0] w_gray10 = ({2'b0, w_r} + {2'b0, w_g} * 2 + {2'b0, w_b}) >> 2;
    wire [7:0] w_gray8  = w_gray10[7:0];
    wire [7:0] w_r_add  = (w_r > 8'd223) ? 8'hFF : (w_r + 8'd32);
    wire [7:0] w_g_add  = (w_g > 8'd223) ? 8'hFF : (w_g + 8'd32);
    wire [7:0] w_b_add  = (w_b > 8'd223) ? 8'hFF : (w_b + 8'd32);

    reg [23:0] r_rgb;
    always @(*) begin
        case (i_mode)
            3'd0:    r_rgb = w_dem_rgb;
            3'd1:    r_rgb = {w_gray8, w_gray8, w_gray8};
            3'd2:    r_rgb = (w_gray8 >= 8'd128) ? 24'hFFFFFF : 24'h000000;
            3'd3:    r_rgb = {w_gray8, w_gray8, w_gray8};   // 原简化边缘已由 imgproc 真 Sobel 取代
            3'd4:    r_rgb = {~w_r, ~w_g, ~w_b};
            3'd5:    r_rgb = {w_b, w_g, w_r};
            default: r_rgb = {w_r_add, w_g_add, w_b_add};
        endcase
    end

    /* ================= 5. 输出寄存 ================= */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_pix_valid       <= 1'b0;
            o_pix_rgb         <= 24'd0;
            o_pix_frame_start <= 1'b0;
            o_pix_line_last   <= 1'b0;
        end else begin
            o_pix_valid       <= w_dem_valid;
            o_pix_frame_start <= w_dem_fs;
            /* 行结束标记当前没被下游使用，先跟着 valid 走（保留原端口） */
            o_pix_line_last   <= w_dem_valid && w_pix_last;
            if (w_dem_valid)
                o_pix_rgb <= r_rgb;
        end
    end

endmodule
