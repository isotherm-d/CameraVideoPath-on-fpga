/* ============================================================================
 * det_bin_open3 —— 1bit 二值掩码 3x3 开运算（腐蚀+膨胀）
 * ============================================================================
 * 用途：串联在 det_cid_filter（多数表决）之后，删除"有 ≥5px 团块但无
 *   3x3 实心核"的残余碎屑。两级叠加后，存活组件均为有实心核心的目标，
 *   det_wbc20 标签消耗降一个量级（README_0920 第 4 节标签耗尽问题的
 *   需求侧治理）。
 *
 * 结构（与 det_cid_filter 已验证的行列约定完全一致）：
 *   腐蚀级：2 行 1bit 行缓存 + 当前行 3 级移位，3x3 全 1 → 1；
 *   膨胀级：2 行 1bit 行缓存 + 当前行 3 级移位，3x3 有 1 → 1。
 *   窗口中心 (x-1) 惯例同 imgproc_win3x3（掩膜整体 +1px 平移，与 cid
 *   滤波器的偏移叠加为 +2px，框精度 ±2px 可接受）。
 *   i_valid→o_valid 固定 6 拍。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_bin_open3 #(
    parameter IMG_W = 1280
) (
    input  wire i_clk,
    input  wire i_rst_n,
    input  wire i_valid,
    input  wire i_bin,
    output wire o_valid,
    output reg  o_bin
);

    /* ================= 腐蚀级 ================= */
    reg ero_l1 [0:IMG_W-1];
    reg ero_l2 [0:IMG_W-1];

    reg        v0;
    reg        b0, b1, b2;              // 当前行 x, x-1, x-2
    reg [11:0] rx;                      // 列计数（行缓存写地址）
    reg        v1;
    reg        c00, c01, c02, c10, c11, c12, c20, c21, c22;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            v0 <= 1'b0; {b0, b1, b2} <= 3'b0; rx <= 12'd0;
        end else begin
            v0 <= i_valid;
            if (i_valid) begin
                b0 <= i_bin; b1 <= b0; b2 <= b1;
                rx <= (rx == IMG_W-1) ? 12'd0 : rx + 12'd1;
            end
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            v1 <= 1'b0;
            {c00, c01, c02, c10, c11, c12, c20, c21, c22} <= 9'b0;
        end else begin
            v1 <= v0;
            if (v0) begin
                ero_l2[rx] <= ero_l1[rx];
                ero_l1[rx] <= b0;
                c00 <= (rx >= 2)   ? ero_l2[rx-2] : 1'b0;
                c01 <= (rx >= 1)   ? ero_l2[rx-1] : 1'b0;
                c02 <= ero_l2[rx];
                c10 <= (rx >= 2)   ? ero_l1[rx-2] : 1'b0;
                c11 <= (rx >= 1)   ? ero_l1[rx-1] : 1'b0;
                c12 <= ero_l1[rx];
                c20 <= (rx >= 2)   ? b2 : 1'b0;
                c21 <= (rx >= 1)   ? b1 : 1'b0;
                c22 <= b0;
            end
        end
    end

    wire w_erode = c00 && c01 && c02 && c10 && c11 && c12 &&
                   c20 && c21 && c22;

    /* ================= 膨胀级 ================= */
    reg dil_l1 [0:IMG_W-1];
    reg dil_l2 [0:IMG_W-1];

    reg        v2;
    reg        e0;                      // 腐蚀输出（x 列）
    reg        v3;
    reg        d0, d1, d2;              // 当前行 x, x-1, x-2（腐蚀值）
    reg [11:0] rxx;
    reg        v4;
    reg        p00, p01, p02, p10, p11, p12, p20, p21, p22;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            v2 <= 1'b0; e0 <= 1'b0;
        end else begin
            v2 <= v1;
            e0  <= w_erode;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            v3 <= 1'b0; {d0, d1, d2} <= 3'b0; rxx <= 12'd0;
        end else begin
            v3 <= v2;
            if (v2) begin
                dil_l2[rxx] <= dil_l1[rxx];
                dil_l1[rxx] <= e0;
                d0 <= e0; d1 <= d0; d2 <= d1;
                rxx <= (rxx == IMG_W-1) ? 12'd0 : rxx + 12'd1;
            end
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            v4 <= 1'b0;
            {p00, p01, p02, p10, p11, p12, p20, p21, p22} <= 9'b0;
        end else begin
            v4 <= v3;
            if (v3) begin
                dil_l2[rxx] <= dil_l1[rxx];
                dil_l1[rxx] <= d0;
                p00 <= (rxx >= 2) ? dil_l2[rxx-2] : 1'b0;
                p01 <= (rxx >= 1) ? dil_l2[rxx-1] : 1'b0;
                p02 <= dil_l2[rxx];
                p10 <= (rxx >= 2) ? dil_l1[rxx-2] : 1'b0;
                p11 <= (rxx >= 1) ? dil_l1[rxx-1] : 1'b0;
                p12 <= dil_l1[rxx];
                p20 <= (rxx >= 2) ? d2 : 1'b0;
                p21 <= (rxx >= 1) ? d1 : 1'b0;
                p22 <= d0;
            end
        end
    end

    assign o_valid = v4;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            o_bin <= 1'b0;
        else if (v4)
            o_bin <= p00 || p01 || p02 || p10 || p11 || p12 ||
                     p20 || p21 || p22;
    end

endmodule
