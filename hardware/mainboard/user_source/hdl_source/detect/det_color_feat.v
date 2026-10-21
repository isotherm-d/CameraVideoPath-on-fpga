/*
 * ============================================================================
 * det_color_feat —— 颜色特征提取（扩展要求 2：目标检测与识别）
 *
 * 在赛题推荐链路
 *     MIPI 输入 → ISP 预处理 → 【颜色/形状特征提取】→ 阈值判定
 *     → 连通域/坐标计算 → OSD 结果叠加 → HDMI 显示
 * 中，本模块负责"颜色特征提取"这一级：把 1 像素/拍的 RGB888 流逐像素换成
 *
 *     HSV 特征（o_hue / o_sat / o_val）+ 8 类颜色分类结果（o_cid）
 *
 * 供下游"阈值判定 / 连通域"模块直接使用（本模块不做连通域，也不出坐标）。
 *
 * ---------------------------------------------------------------------------
 * 颜色分类编码 o_cid（3bit）：
 *     0 = NONE   背景/未分类（太暗，或低饱和的中性色）
 *     1 = RED    红    （H <  30°  或 H >= 330°）
 *     2 = YELLOW 黄    （30° <= H <  70°，含橙色）
 *     3 = GREEN  绿    （70° <= H < 160°）
 *     4 = CYAN   青    （160° <= H < 200°）
 *     5 = BLUE   蓝    （200° <= H < 280°）
 *     6 = MAGENTA 品红（280° <= H < 330°）
 *     7 = WHITE  白    （亮 且 低饱和）
 * 判决顺序（重要，参考模型必须一致）：
 *     1) v  <  V_MIN   -> NONE（太暗，色相不可信）
 *     2) sat < S_MIN   -> v >= WHITE_V ? WHITE : NONE（低饱和中性色）
 *     3) 否则按 o_hue 落在哪个色相区间分类
 *
 * ---------------------------------------------------------------------------
 * RGB -> HSV 的硬件实现（全程整数，无除法器）：
 *
 *   V = max(R,G,B)；C = V - min(R,G,B)（色度）
 *   S = round(255 * C / V)   —— 用倒数 ROM 近似：S = (C * rcp(V)) >> 8
 *   H = 按最大通道分扇区（R:0 / G:120° / B:240°），
 *       扇区内偏移 = |两非最大通道之差| / C 映射到 0~60°，
 *       同样用倒数 ROM：frac = (|diff| * rcp(C)) >> 8
 *
 *   倒数 ROM：rcp(d) = round(65536/d)，256 字 x 17bit，initial 循环初始化
 *   （TD 支持 initial 初值的 ROM 推断；ROM 是常量，不参与复位清零，
 *    和 imgproc_win3x3 的行缓存同一个处理思路）。
 *
 *   色相标度 o_hue：10bit，0~1023 线性对应 0°~360°（每 LSB ≈ 0.352°）。
 *     扇区基址 R=0 / G=341 / B=683；扇区内偏移 frac10 = frac * 171 >> 8
 *     （0~255 的 frac 映射到 0~170，170/1024 ≈ 59.8° ≈ 60°）。
 *     R 扇区且 B>G 时色相在 360° 附近回绕：hue = 1024 - frac10（10bit 截断，
 *     frac10=0 时正好回 0）。
 *
 *   rcp 取整会使 S / frac 比"精确值"大 0~1 LSB，因此两处都做了 255 饱和；
 *   逐位与 TB 参考模型完全一致（参考模型用同一个 rcp 表达式）。
 *
 * ---------------------------------------------------------------------------
 * 接口与时序：和 imgproc_top 完全同款的流式像素接口
 *     i_valid 高时 i_rgb 有效，1 像素/拍，允许任意拍气泡；
 *     i_frame_start 与一帧第 2 个输入像素同拍（cvp_proc 齿轮箱约定）。
 *     i_valid -> o_valid 固定 4 拍，i_frame_start 同拍挪 4 拍。
 *     本模块是纯逐像素运算（无空间窗口）：喂哪个像素就出哪个像素的特征。
 *     det_feat_top 把 3x3 窗口中心 p11 喂进来，颜色特征就和形状特征描述
 *     同一个像素（窗口中心 = 源图 (x-1,y-1)）；单独使用时直接接像素流，
 *     特征描述的就是当拍输入像素。
 *
 * 资源：2 块 256x17 ROM（V 和 C 各一个读口）+ 3 个小乘法（8x17 x2、8x8 x1，
 *       可落 DSP）+ 少量比较器；无行缓存、无除法器。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_color_feat #(
    parameter [7:0] V_MIN   = 8'd40,    // 暗判决：V 低于此值判 NONE
    parameter [7:0] S_MIN   = 8'd60,    // 低饱和判决：S 低于此值走白/背景支路
    parameter [7:0] WHITE_V = 8'd200,   // 低饱和且亮于此值 -> WHITE

    /* 色相分界（hue10 标度，360°=1024）：R|Y|G|C|M|B 六个区间 */
    parameter [9:0] HUE_RY  = 10'd85,    //  30°  红/黄
    parameter [9:0] HUE_YG  = 10'd199,   //  70°  黄/绿
    parameter [9:0] HUE_GC  = 10'd455,   // 160°  绿/青
    parameter [9:0] HUE_CB  = 10'd569,   // 200°  青/蓝
    parameter [9:0] HUE_BM  = 10'd796,   // 280°  蓝/品红
    parameter [9:0] HUE_MR  = 10'd939    // 330°  品红/红
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_valid,
    input  wire [23:0] i_rgb,
    input  wire        i_frame_start,

    output reg         o_valid,
    output reg         o_frame_start,
    output reg  [9:0]  o_hue,           // 0~1023 <-> 0°~360°
    output reg  [7:0]  o_sat,           // 0~255
    output reg  [7:0]  o_val,           // 0~255 = max(R,G,B)
    output reg  [2:0]  o_cid            // 颜色分类，见文件头编码表
);

    /* 颜色分类编码 */
    localparam [2:0] CID_NONE = 3'd0,
                     CID_RED  = 3'd1,
                     CID_YEL  = 3'd2,
                     CID_GRN  = 3'd3,
                     CID_CYN  = 3'd4,
                     CID_BLU  = 3'd5,
                     CID_MAG  = 3'd6,
                     CID_WHT  = 3'd7;

    wire [7:0] px_r = i_rgb[23:16];
    wire [7:0] px_g = i_rgb[15:8];
    wire [7:0] px_b = i_rgb[7:0];

    /* ================= C1：max / min / 扇区 / 色度（组合，打 1 拍） ================= */
    wire [7:0] w_max = (px_r >= px_g) ? ((px_r >= px_b) ? px_r : px_b)
                     : ((px_g >= px_b) ? px_g : px_b);
    wire [7:0] w_min = (px_r <= px_g) ? ((px_r <= px_b) ? px_r : px_b)
                     : ((px_g <= px_b) ? px_g : px_b);
    wire [7:0] w_c   = w_max - w_min;

    /* 扇区：0=R 最大，1=G 最大，2=B 最大（并列时优先 R>G>B，和 max 的取法一致） */
    wire [1:0] w_sec = (px_r >= px_g && px_r >= px_b) ? 2'd0 :
                       (px_g >= px_b)                 ? 2'd1 : 2'd2;

    /* 色相分子：扇区内"正向通道 - 负向通道"
     *   R 扇区: pos=G neg=B（G>=B 色相在 0~60°，否则在 300~360° 回绕）
     *   G 扇区: pos=B neg=R（基址 120°）
     *   B 扇区: pos=R neg=G（基址 240°） */
    wire [7:0] w_pos = (w_sec == 2'd0) ? px_g :
                       (w_sec == 2'd1) ? px_b : px_r;
    wire [7:0] w_neg = (w_sec == 2'd0) ? px_b :
                       (w_sec == 2'd1) ? px_r : px_g;
    wire       w_posf = (w_pos >= w_neg);
    wire [7:0] w_habs = w_posf ? (w_pos - w_neg) : (w_neg - w_pos);

    reg        r_v1, r_fs1;
    reg [7:0]  r_v, r_c, r_habs;
    reg [1:0]  r_sec;
    reg        r_posf;

    /* ================= 倒数 ROM：rcp(d) = round(65536/d) ================= */
    /* V、C 两个地址同时读，所以例化两份；index 0 不会用到有效判决里
     * （C=0 时 sat/hue 都会被阈值支路拦下），填 0 防止 X 扩散。 */
    reg [16:0] rom_rcv [0:255];
    reg [16:0] rom_rcc [0:255];
    integer    i;
    initial begin
        rom_rcv[0] = 17'd0;
        rom_rcc[0] = 17'd0;
        for (i = 1; i < 256; i = i + 1) begin
            rom_rcv[i] = (65536 + i/2) / i;
            rom_rcc[i] = (65536 + i/2) / i;
        end
    end

    /* ================= C2：S = C*rcp(V)>>8，frac = |diff|*rcp(C)>>8 ================= */
    /* 乘法在 25bit 上下文里算全积（最大 255*65536），再取高 8 位；
     * rcp 上取整可能让结果到 256，两处都饱和到 255。 */
    wire [24:0] w_sat_p  = r_c    * rom_rcv[r_v];
    wire [24:0] w_frac_p = r_habs * rom_rcc[r_c];
    wire [7:0]  w_sat    = (w_sat_p  [24:8] > 17'd255) ? 8'd255 : w_sat_p  [15:8];
    wire [7:0]  w_frac   = (w_frac_p [24:8] > 17'd255) ? 8'd255 : w_frac_p [15:8];

    reg        r_v2, r_fs2;
    reg [7:0]  r_sat, r_frac, r_vv2;
    reg [1:0]  r_sec2;
    reg        r_posf2;

    /* ================= C3：hue10 + 颜色分类（组合，打 1 拍） ================= */
    wire [15:0] w_f10p  = r_frac * 8'd171;             // 0~255 -> 0~170
    wire [9:0]  w_f10   = w_f10p[15:8];
    wire [9:0]  w_base  = (r_sec2 == 2'd2) ? 10'd683 :
                          (r_sec2 == 2'd1) ? 10'd341 : 10'd0;
    wire [10:0] w_hue_rn = 11'd1024 - {1'b0, w_f10};   // R 扇区 360° 侧回绕

    wire [9:0]  w_hue = (r_sec2 == 2'd0)
                        ? (r_posf2 ? w_f10 : w_hue_rn[9:0])
                        : (r_posf2 ? (w_base + w_f10) : (w_base - w_f10));

    /* 分类：先暗、再低饱和、最后按色相区间 */
    wire [2:0]  w_cid_h = (w_hue >= HUE_MR || w_hue < HUE_RY) ? CID_RED :
                          (w_hue < HUE_YG) ? CID_YEL :
                          (w_hue < HUE_GC) ? CID_GRN :
                          (w_hue < HUE_CB) ? CID_CYN :
                          (w_hue < HUE_BM) ? CID_BLU : CID_MAG;
    wire [2:0]  w_cid = (r_vv2 < V_MIN) ? CID_NONE :
                        (r_sat  < S_MIN) ? ((r_vv2 >= WHITE_V) ? CID_WHT : CID_NONE)
                                         : w_cid_h;

    reg        r_v3, r_fs3;
    reg [9:0]  r_hue;
    reg [7:0]  r_sat3, r_v3v;
    reg [2:0]  r_cid;

    /* ================= C4：输出寄存（与 det_shape_feat 对齐到同一拍） ================= */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            /* C1 */
            r_v1 <= 1'b0;  r_fs1 <= 1'b0;
            r_v <= 8'd0;  r_c <= 8'd0;  r_habs <= 8'd0;
            r_sec <= 2'd0;  r_posf <= 1'b0;
            /* C2 */
            r_v2 <= 1'b0;  r_fs2 <= 1'b0;
            r_sat <= 8'd0;  r_frac <= 8'd0;  r_vv2 <= 8'd0;
            r_sec2 <= 2'd0;  r_posf2 <= 1'b0;
            /* C3 */
            r_v3 <= 1'b0;  r_fs3 <= 1'b0;
            r_hue <= 10'd0;  r_sat3 <= 8'd0;  r_v3v <= 8'd0;  r_cid <= 3'd0;
            /* C4 */
            o_valid <= 1'b0;  o_frame_start <= 1'b0;
            o_hue <= 10'd0;  o_sat <= 8'd0;  o_val <= 8'd0;  o_cid <= 3'd0;
        end else begin
            /* ---------- C1 ---------- */
            r_v1 <= i_valid;
            if (i_valid) begin
                r_fs1  <= i_frame_start;
                r_v    <= w_max;
                r_c    <= w_c;
                r_habs <= w_habs;
                r_sec  <= w_sec;
                r_posf <= w_posf;
            end

            /* ---------- C2 ---------- */
            r_v2 <= r_v1;
            if (r_v1) begin
                r_fs2   <= r_fs1;
                r_sat   <= w_sat;
                r_frac  <= w_frac;
                r_vv2   <= r_v;
                r_sec2  <= r_sec;
                r_posf2 <= r_posf;
            end

            /* ---------- C3 ---------- */
            r_v3 <= r_v2;
            if (r_v2) begin
                r_fs3  <= r_fs2;
                r_hue  <= w_hue;
                r_sat3 <= r_sat;
                r_v3v  <= r_vv2;
                r_cid  <= w_cid;
            end

            /* ---------- C4 ---------- */
            o_valid <= r_v3;
            if (r_v3) begin
                o_frame_start <= r_fs3;
                o_hue <= r_hue;
                o_sat <= r_sat3;
                o_val <= r_v3v;
                o_cid <= r_cid;
            end
        end
    end

endmodule
