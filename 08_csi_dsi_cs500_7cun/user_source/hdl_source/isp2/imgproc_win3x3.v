/*
 * ============================================================================
 * imgproc_win3x3 —— 3x3 像素窗口生成（三种算法共用的前端）
 *
 * 作用：把 1 像素/拍的 RGB888 流，变成 3x3 邻域，送给高斯/中值/Sobel。
 *
 * ---------------------------------------------------------------------------
 * 【重要】窗口到底对准哪个像素？—— 流式通路的固有时延
 *
 * 3x3 滤波需要“下一行”的像素，而下一行比当前行晚整整一行才到，
 * 所以硬件不可能在像素 (x,y) 到达的当拍就给出“以 (x,y) 为中心”的窗口。
 *
 * 本模块的选择是：窗口跟着流水线自然走，输出槽位 (x,y) 上给出的窗口是
 *
 *           x-2    x-1     x          ← 源图列号
 *   y-2     p00    p01    p02
 *   y-1     p10    p11    p12
 *   y      (p20)  (p21)   p22
 *
 * 其中 **中心像素是 p11，对应源图坐标 (x-1, y-1)**，p22 才是当拍的输入像素。
 * 等价说法：out(槽位 x,y) = 算法(中心 x-1, y-1)。
 * 也就是说整幅图在空间上“右下各偏 1 个像素”，这就是 3x3 邻域算法
 * 在流式结构里无法避免的固有延迟（1 行 + 1 像素）。
 *
 * 对显示的影响：整幅画面平移 1 个像素，肉眼不可见，帧率/时序完全不变；
 * 但如果做“原图 vs 算法”逐像素对比，必须以 (x-1,y-1) 为准，否则会差一圈。
 * 所以 imgproc_top 里的直通支路也统一走 p11，保证切算法时画面不跳。
 * （若今后要求严格 0 偏移，需要上游多送 1 行 + 1 像素的“消隐”像素来冲掉它。）
 * ---------------------------------------------------------------------------
 *
 * 边界处理：采用“复制边界”（replicate）。第 0/1 行、第 0/1 列没有邻居时
 *           用自己/上一行代替，这样输入 W x H 就输出 W x H 个像素，
 *           下游帧缓存不需要改任何时序。
 *
 * 实现方式：
 *   - 两个行缓存 buf_a / buf_b：行 y 写进 buf[y[0]]，那么 y-1 行在另一块、
 *     y-2 行在本块同址（靠“同一拍先读后写”拿到旧值，和 cvp_proc.v 一致）；
 *   - 行内 x-1 / x-2 用寄存器移位链；
 *   - 行缓存是“地址打一拍”的同步读写法，综合器可推断成 ERAM/BRAM。
 *
 * 时序：i_valid 到 o_valid 固定 2 拍；i_frame_start 跟着 o_valid 同拍挪 2 拍，
 *       所以下游帧缓存看到的“帧起始”和像素边沿仍然是对齐的。
 *       imgproc_top 里的算法再打 1 拍，整条通路共 3 拍。
 * ============================================================================
 */
`timescale 1ns/1ps

module imgproc_win3x3 #(
    parameter IMG_W = 1024,          // 图像宽（一行缓存的深度）
    parameter IMG_H = 600,           // 图像高（跟例程 lab_hd_1 的拍摄规格：1024x600）
    parameter DW    = 24             // 像素位宽 RGB888
) (
    input  wire          i_clk,
    input  wire          i_rst_n,

    /* 像素输入（1 像素/拍，RGB888，和 cvp_proc 输出一致） */
    input  wire          i_valid,
    input  wire [DW-1:0] i_data,
    input  wire          i_frame_start,   // 与某一拍 i_valid 同拍，标记一帧第 2 个像素

    /* 3x3 窗口输出，与 o_valid 同拍有效；中心是 p11 */
    output reg           o_valid,
    output reg           o_frame_start,
    output reg  [DW-1:0] o_p00, o_p01, o_p02,
    output reg  [DW-1:0] o_p10, o_p11, o_p12,
    output reg  [DW-1:0] o_p20, o_p21, o_p22
);

    /* ================= 1. 行缓存 ================= */
    reg [DW-1:0] buf_a [0:IMG_W-1];      // 偶数行
    reg [DW-1:0] buf_b [0:IMG_W-1];      // 奇数行

    /* ================= 2. P0：地址 / 写缓存 / 读数 ================= */
    reg [10:0]   r_x, r_y;               // 输入侧列/行计数
    reg [10:0]   r_x_d, r_y_d;           // 打到 P1 的列/行计数
    reg [DW-1:0] r_cur_d;                // 打到 P1 的当前像素
    reg [DW-1:0] r_up1, r_up2;           // y-1 / y-2 行同列像素（同步读结果）
    reg          r_v1;                   // 输入 valid 打一拍
    reg          r_fs_d;                 // 帧起始打一拍，与 r_cur_d 同步

    /* 读：行 y 写在 buf[y[0]]，则 y-1 在另一块、y-2 在本块 */
    wire [DW-1:0] w_rd_up1 = r_y[0] ? buf_a[r_x] : buf_b[r_x];
    wire [DW-1:0] w_rd_up2 = r_y[0] ? buf_b[r_x] : buf_a[r_x];

    /* ================= 3. P1：边界夹紧 + 行内移位链 ================= */
    /* 垂直方向：第 0 行没有上一行 -> 用自己；第 1 行没有上上行 -> 用上一行 */
    wire [DW-1:0] w_up1 = (r_y_d >= 11'd1) ? r_up1 : r_cur_d;
    wire [DW-1:0] w_up2 = (r_y_d >= 11'd2) ? r_up2 : w_up1;

    /* 行内 x-1 / x-2（第 0、1 列做复制边界） */
    reg  [DW-1:0] r2a, r2b;              // 当前行：x-1、x-2
    reg  [DW-1:0] r1a, r1b;              // y-1 行：x-1、x-2
    reg  [DW-1:0] r0a, r0b;              // y-2 行：x-1、x-2

    wire [DW-1:0] w_c_a = (r_x_d == 11'd0) ? r_cur_d : r2a;
    wire [DW-1:0] w_c_b = (r_x_d == 11'd0) ? r_cur_d :
                          (r_x_d == 11'd1) ? r2a : r2b;
    wire [DW-1:0] w_1_a = (r_x_d == 11'd0) ? w_up1 : r1a;
    wire [DW-1:0] w_1_b = (r_x_d == 11'd0) ? w_up1 :
                          (r_x_d == 11'd1) ? r1a : r1b;
    wire [DW-1:0] w_0_a = (r_x_d == 11'd0) ? w_up2 : r0a;
    wire [DW-1:0] w_0_b = (r_x_d == 11'd0) ? w_up2 :
                          (r_x_d == 11'd1) ? r0a : r0b;

    /* ================= 4. 主时序 ================= */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_x <= 11'd0; r_y <= 11'd0;
            r_x_d <= 11'd0; r_y_d <= 11'd0;
            r_cur_d <= {DW{1'b0}};
            r_up1 <= {DW{1'b0}}; r_up2 <= {DW{1'b0}};
            r_v1 <= 1'b0;
            r_fs_d <= 1'b0;
            r2a <= {DW{1'b0}}; r2b <= {DW{1'b0}};
            r1a <= {DW{1'b0}}; r1b <= {DW{1'b0}};
            r0a <= {DW{1'b0}}; r0b <= {DW{1'b0}};
            o_valid <= 1'b0;
            o_frame_start <= 1'b0;
            o_p00 <= {DW{1'b0}}; o_p01 <= {DW{1'b0}}; o_p02 <= {DW{1'b0}};
            o_p10 <= {DW{1'b0}}; o_p11 <= {DW{1'b0}}; o_p12 <= {DW{1'b0}};
            o_p20 <= {DW{1'b0}}; o_p21 <= {DW{1'b0}}; o_p22 <= {DW{1'b0}};
        end else begin
            /* ---------- P0：输入边 ---------- */
            r_v1 <= i_valid;
            if (i_valid) begin
                /* y-1 / y-2 行同列像素（同步读，下一拍有效） */
                r_up1 <= w_rd_up1;
                r_up2 <= w_rd_up2;
                /* 当前行写进 buf[y[0]]；y-2 行同址读是“先读后写” */
                if (r_y[0]) buf_b[r_x] <= i_data;
                else        buf_a[r_x] <= i_data;

                /* 打一拍给 P1（帧起始跟着当前像素一起打拍） */
                r_cur_d <= i_data;
                r_x_d   <= r_x;
                r_y_d   <= r_y;
                r_fs_d  <= i_frame_start;

                /* 列/行计数（行满一帧回绕）
                 * v13e: 帧首像素标记拍强制对齐 r_x/r_y=0 —— 原自计数相位取决于
                 * 上电后首个 valid 的随机时刻, 列相位随机偏移导致 demosaic 的
                 * BGGR 平面错位(B 偏色)。语义: i_frame_start 与帧首 valid 同拍。 */
                if (i_frame_start) begin
                    r_x <= 11'd1;      // 本拍像素=列0, 下一拍列1
                    r_y <= 11'd0;
                end else if (r_x == IMG_W-1) begin
                    r_x <= 11'd0;
                    r_y <= (r_y == IMG_H-1) ? 11'd0 : (r_y + 11'd1);
                end else begin
                    r_x <= r_x + 11'd1;
                end
            end

            /* ---------- P1：移位链（左边邻居） ---------- */
            if (r_v1) begin
                r2a <= r_cur_d;  r2b <= w_c_a;
                r1a <= w_up1;    r1b <= w_1_a;
                r0a <= w_up2;    r0b <= w_0_a;
            end

            /* ---------- P2：窗口输出（中心是 p11） ---------- */
            o_valid <= r_v1;
            if (r_v1) begin
                o_frame_start <= r_fs_d;
                o_p00 <= w_0_b; o_p01 <= w_0_a; o_p02 <= w_up2;
                o_p10 <= w_1_b; o_p11 <= w_1_a; o_p12 <= w_up1;
                o_p20 <= w_c_b; o_p21 <= w_c_a; o_p22 <= r_cur_d;
            end
        end
    end

endmodule