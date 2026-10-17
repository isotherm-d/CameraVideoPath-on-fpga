/* ============================================================================
 * cvp_box_overlay —— 白细胞检测框视频叠加（detect 组，2026-10-12）
 * ============================================================================
 * 功能：在 1 像素/拍的 RGB 视频流上叠加矩形框——常量测试框（验证通路）+
 * 检测框（det_wbc20 输出直驱）。框"烤"进像素里，任何下游显示（PC GUI/
 * DSI 屏/ETHB 镜像→副板 HDMI）都免计算直接看到框。
 *
 * 背景：描述符画框链（det_wbc20→det_roi_bridge→result_*→UDP6002→GUI）
 * 依赖 clean 流的 frame_id 与视频帧元数据精确匹配，板上实测匹配失败
 * （2026-10-12 首次上板，clean 抽头疑似未工作）。本模块绕开该链。
 *
 * 用法：插在 cvp_advanced 输出与 pack_4 之间（100MHz、1 像素/拍、
 * 24bit RGB888）。x/y 由 sof + 行宽计数生成（流上无 eol 标记）。
 * 组合覆写零延迟，流时序不变。
 *
 * 框格式：i_box_xy/i_test_box 每框 48bit={x0,y0,x1,y1} 各 12bit
 * （与 det_wbc20 o_box_xy 一致；全 F 框因坐标 >IMG_W 天然不命中）。
 * 检测框在 i_box_toggle（每帧一翻）沿锁存，滞后检测帧一帧——白细胞
 * 帧间移动 ~1px，观感无影响。空心描边 2px（BORDER_T），框内目标可见。
 * 检测框锁存时四边外扩 BOX_MARGIN 像素（默认 16，钳到屏内）——给淡染
 * 边缘留余量；测试框不外扩。退化/空槽框（全 F、全 0）不画。
 * ============================================================================
 */
`timescale 1ns/1ps

module cvp_box_overlay #(
    parameter N_BOX = 5,
    parameter IMG_W = 1280,
    parameter IMG_H = 720,
    parameter BOX_MARGIN = 16   /* 检测框四边外扩像素数（0=原框；10-17 由 8 调 16） */
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    /* 显示像素流（1 像素/拍） */
    input  wire        i_valid,
    input  wire        i_sof,
    input  wire [23:0] i_rgb,
    output wire        o_valid,
    output wire        o_sof,
    output wire [23:0] o_rgb,
    /* 检测框（det_wbc20 直驱，toggle 每帧翻转锁存） */
    input  wire [N_BOX*48-1:0] i_box_xy,
    input  wire        i_box_toggle,
    /* 常量测试框（叠加通路自检） */
    input  wire [47:0] i_test_box,
    input  wire        i_test_en,
    /* 诊断：原始分类标记（det_color_feat 输出直通，cid==5 像素涂白） */
    input  wire        i_mark_valid,
    input  wire [2:0]  i_mark_cid,
    input  wire        i_mark_en
);
    /* ---- x/y 光栅计数（sof 归零；行宽由 IMG_W 参数决定，流上无 eol） ---- */
    reg [11:0] r_x, r_y;
    wire w_last_col = (r_x == IMG_W-1);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_x <= 12'd0; r_y <= 12'd0;
        end else if (i_valid) begin
            if (i_sof) begin
                r_x <= 12'd0; r_y <= 12'd0;
            end else if (w_last_col) begin
                r_x <= 12'd0;
                r_y <= (r_y == IMG_H-1) ? 12'd0 : r_y + 12'd1;
            end else begin
                r_x <= r_x + 12'd1;
            end
        end
    end

    /* ---- 检测框快照（toggle 沿锁存，滞后检测帧一帧） --------------------
     * 锁存时四边外扩 BOX_MARGIN 像素并钳到屏内：淡染细胞边缘落在分类掩膜
     * 外（cid_filter+open3 合计收缩 2~3px + 染色梯度数 px），外接框需留
     * 余量。纯加法零乘法，只在锁存拍计算（每帧一次），不在逐像素通路上。
     * 退化框（全 F 空槽 BOX_OFF、全 0、x1<=x0 或 y1<=y0）锁存倒置坐标
     * 永不命中——同时消除零框在原点的描边点。 */
    reg [11:0] r_bx0 [0:N_BOX-1];
    reg [11:0] r_by0 [0:N_BOX-1];
    reg [11:0] r_bx1 [0:N_BOX-1];
    reg [11:0] r_by1 [0:N_BOX-1];
    /* 槽字段展开中间量（锁存拍内阻塞赋值，逐槽复用）：
     * x0=槽[47:36] y0=槽[35:24] x1=槽[23:12] y1=槽[11:0]（x0 最高位，
     * 与 det_wbc20 打包一致） */
    reg [47:0] v_slot;
    reg [11:0] v_x0, v_y0, v_x1, v_y1;
    integer k1;
    always @(posedge i_clk) begin
        if (i_box_toggle) begin
            for (k1 = 0; k1 < N_BOX; k1 = k1 + 1) begin
                v_slot = i_box_xy[k1*48 +: 48];
                v_x0 = v_slot[47:36]; v_y0 = v_slot[35:24];
                v_x1 = v_slot[23:12]; v_y1 = v_slot[11:0];
                if ((v_x1 > v_x0) && (v_y1 > v_y0)) begin
                    r_bx0[k1] <= (v_x0 > BOX_MARGIN) ? v_x0 - BOX_MARGIN : 12'd0;
                    r_by0[k1] <= (v_y0 > BOX_MARGIN) ? v_y0 - BOX_MARGIN : 12'd0;
                    r_bx1[k1] <= (v_x1 >= IMG_W-BOX_MARGIN) ? IMG_W-1
                                                            : v_x1 + BOX_MARGIN;
                    r_by1[k1] <= (v_y1 >= IMG_H-BOX_MARGIN) ? IMG_H-1
                                                            : v_y1 + BOX_MARGIN;
                end else begin
                    r_bx0[k1] <= 12'hFFF; r_by0[k1] <= 12'hFFF;
                    r_bx1[k1] <= 12'h000; r_by1[k1] <= 12'h000;
                end
            end
        end
    end

    /* ---- 空心描边（BORDER_T 像素宽，与 PC GUI 框线一致） ------------------
     * 只画边框线：in_range 保证无符号减法不下溢；框内不覆写，目标可见 */
    localparam [11:0] BORDER_T = 12'd2;

    wire [11:0] w_tx0 = i_test_box[47:36], w_ty0 = i_test_box[35:24];
    wire [11:0] w_tx1 = i_test_box[23:12], w_ty1 = i_test_box[11:0];
    wire w_t_in_x = (r_x >= w_tx0) && (r_x <= w_tx1);
    wire w_t_in_y = (r_y >= w_ty0) && (r_y <= w_ty1);
    wire w_test_hit = i_test_en && w_t_in_x && w_t_in_y &&
        ((r_x - w_tx0 < BORDER_T) || (w_tx1 - r_x < BORDER_T) ||
         (r_y - w_ty0 < BORDER_T) || (w_ty1 - r_y < BORDER_T));

    reg w_det_hit;
    integer k2;
    always @(*) begin
        w_det_hit = 1'b0;
        for (k2 = 0; k2 < N_BOX; k2 = k2 + 1)
            if ((r_x >= r_bx0[k2]) && (r_x <= r_bx1[k2]) &&
                (r_y >= r_by0[k2]) && (r_y <= r_by1[k2]) &&
                (((r_x - r_bx0[k2]) < BORDER_T) || ((r_bx1[k2] - r_x) < BORDER_T) ||
                 ((r_y - r_by0[k2]) < BORDER_T) || ((r_by1[k2] - r_y) < BORDER_T)))
                w_det_hit = 1'b1;
    end

    wire w_hit = w_test_hit || w_det_hit;

    assign o_valid = i_valid;
    assign o_sof   = i_sof;
    wire w_mark_paint = i_mark_en && i_mark_valid && (i_mark_cid == 3'd5);
    assign o_rgb   = w_hit            ? 24'h00FF00 :
                     w_mark_paint     ? 24'hFFFFFF : i_rgb;   // 白点=原始分类标记

endmodule
