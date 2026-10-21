/* ============================================================================
 * det_cid_filter —— cid 流 3x3 多数表决 v2（2026-10-10，真实帧联仿产物）
 * ============================================================================
 * 背景（README_0920 第 4/5 节）：S_MIN=100 真实帧碎屑游程 ~237+/帧耗尽
 *   det_wbc20 标签预算。本模块用 3x3 多数表决在源头填洞/杀孤立噪点。
 *
 * 【v2 语义关键——为什么是多数表决而不是形态学开】开运算（腐蚀+膨胀）
 *   让掩码变瘦 → CCL 碎片化更严重 → union-find 合并链更深 → find 失效
 *   恶化（实测 open(3) 后出现 1074x6 假条带）。多数表决让掩码变胖（填
 *   1px 洞）→ 细胞成整块 → 合并少 → 链浅 → find3 覆盖。与 S60 时代
 *   "胖掩码少合并"的可工作条件对齐。
 *
 * 规则（窗口 9 格中 WBC_CID 计数 = count5）：
 *   count5 >= 5          -> 输出 WBC_CID（实心块保留、1px 洞填补）
 *   count5 < 5 且中心==5 -> 输出 NONE（孤立/薄碎屑死：1px、1px 线、对角对）
 *   其余                 -> 透传 center（其他颜色类不受影响）
 *   边缘代价：核边缘/角落腐蚀 1px——COMPACT_PCT=37 容忍。
 *
 * 结构：2 行 cid 行缓存（3b x 1280 LUTRAM）+ 当前行 3 级移位 + 2 拍表决，
 *   i_valid→o_valid 固定 3 拍。窗口中心 (x-1) 惯例同 imgproc_win3x3
 *   （掩膜整体 +1px 平移，框精度 ±1px 可接受）。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_cid_filter #(
    parameter IMG_W = 1280,
    parameter [2:0] WBC_CID = 3'd5
) (
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_valid,
    input  wire [2:0] i_cid,
    output reg        o_valid,
    output reg  [2:0] o_cid
);

    /* ---------------- 行缓存：y-1 / y-2 行的 cid ---------------- */
    reg [2:0] line1 [0:IMG_W-1];
    reg [2:0] line2 [0:IMG_W-1];

    /* ---------------- 当前行 3 级移位 + 列计数 + 行缓存写 ---------------- */
    reg       r_v0;
    reg [2:0] h0, h1, h2;                   // x, x-1, x-2（当前行）
    reg [11:0] r_x;                         // 列计数（行缓存写地址）
    reg       r_v1;
    reg [2:0] r_w00, r_w01, r_w02;          // y-2 行：x-2, x-1, x
    reg [2:0] r_w10, r_w11, r_w12;          // y-1 行
    reg [2:0] r_w20, r_w21, r_w22;          // y   行
    reg [2:0] r_c1;                         // 中心像素原 cid（=x-1 列）
    reg       r_v2;
    reg [2:0] r_c2;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_v0 <= 1'b0; {h0, h1, h2} <= 9'd0;
            r_x  <= 12'd0;
        end else begin
            r_v0 <= i_valid;
            if (i_valid) begin
                h0 <= i_cid;
                h1 <= h0;
                h2 <= h1;
                r_x <= (r_x == IMG_W-1) ? 12'd0 : r_x + 12'd1;
            end
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_v1 <= 1'b0;
            {r_w00, r_w01, r_w02} <= 9'd0;
            {r_w10, r_w11, r_w12} <= 9'd0;
            {r_w20, r_w21, r_w22} <= 9'd0;
            r_c1 <= 3'd0;
        end else begin
            r_v1 <= r_v0;
            if (r_v0) begin
                /* 行缓存移位：当前列 line1 → line2，当前 cid → line1
                 *（【修正 2026-10-10】行缓存按列地址 r_x 寻址——原版误用
                 *  cid 移位寄存器 h2/h1/h0 做地址（3bit 值当 0-7 列地址），
                 *  窗口采样全错，真实帧全行误判紫、标签表被垃圾游程打爆） */
                line2[r_x] <= line1[r_x];
                line1[r_x] <= h0;
                r_w00 <= (r_x < 2)   ? 3'd0 : line2[r_x - 2];
                r_w01 <= (r_x < 1)   ? 3'd0 : line2[r_x - 1];
                r_w02 <= line2[r_x];
                r_w10 <= (r_x < 2)   ? 3'd0 : line1[r_x - 2];
                r_w11 <= (r_x < 1)   ? 3'd0 : line1[r_x - 1];
                r_w12 <= line1[r_x];
                r_w20 <= h2;
                r_w21 <= h1;
                r_w22 <= h0;
                r_c1  <= h1;                    // 中心 = x-1 列
            end
        end
    end

    /* S2：计数 + 表决（组合计数，寄存结果） */
    wire [4:0] w_cnt5 = ((r_w00 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w01 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w02 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w10 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w11 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w12 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w20 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w21 == WBC_CID) ? 5'd1 : 5'd0) +
                        ((r_w22 == WBC_CID) ? 5'd1 : 5'd0);

    reg       r_maj;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_v2 <= 1'b0; r_c2 <= 3'd0; r_maj <= 1'b0;
        end else begin
            r_v2  <= r_v1;
            r_c2  <= r_c1;
            r_maj <= (w_cnt5 >= 5'd5);
        end
    end

    /* S3：输出裁定 */
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_valid <= 1'b0;
            o_cid   <= 3'd0;
        end else begin
            o_valid <= r_v2;
            if (r_v2) begin
                if (r_maj)
                    o_cid <= WBC_CID;                 // 多数紫：判紫（填 1px 洞）
                else if (r_c2 == WBC_CID)
                    o_cid <= 3'd0;                    // 孤立紫：杀
                else
                    o_cid <= r_c2;                    // 其他类透传
            end
        end
    end

endmodule
