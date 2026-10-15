/* ============================================================================
 * u_roi_pixfill —— 检测框内 32x32 灰度小图裁剪填充（2026-10-10）
 * ============================================================================
 * 职责：clean 流（RGB888 + x/y 坐标）流过时，按当前检测框快照，把每个
 *   框的 32x32 区域转灰度（g=(R+2G+B)>>2，与 imgproc 灰度同式）裁剪到
 *   每框 1KB 缓存；逐框"已捕获"标志供 det_roi_bridge 按框门控发送。
 *
 * 数据流（帧 N+1 期间）：
 *   框快照（帧 N 末 toggle 锁存，与 bridge 同源同刻）在帧 N+1 全程有效；
 *   流水行 y 落入框 k 的 [y0, y0+31] 时，列 x∈[x0, x0+31] 的灰度写入
 *   buf_k[(y-y0)*32 + (x-x0)]；行末若本行是框 k 的第 32 行，captured[k]=1。
 *   bridge 发送框 k 的块时按 o_pix_req 逐字节读 buf_k。
 *
 * 【框小于 32x32】裁剪窗锚定框左上角，固定 32x32；框右/下不足的部分
 *   保留 0 或旧内容（分类侧按 bbox 判断有效区，可接受）。
 * 【时序】框比像素老一帧（33ms 内细胞移动 <1px，可接受；V26 协议以
 *   frame_id 对齐并容忍迟到）。
 * 【资源】10 框 x 1KB 寄存器数组 → 综合映射 LUTRAM（新工程 slice 充裕）。
 * ============================================================================
 */
`timescale 1ns/1ps

module u_roi_pixfill #(
    parameter integer N_BOX = 5,
    parameter IMG_W = 1280,
    parameter IMG_H = 720
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    /* clean 流抽头（与 det 链同源） */
    input  wire        i_pix_valid,
    input  wire [11:0] i_pix_x,
    input  wire [11:0] i_pix_y,
    input  wire [23:0] i_pix_rgb,

    /* 框快照（与 bridge 同源：det_wbc20 框总线 + toggle） */
    input  wire [N_BOX*48-1:0] i_box_xy,
    input  wire        i_box_toggle,

    /* 每框捕获完成标志（bridge 按框门控） */
    output wire [N_BOX-1:0] o_captured,

    /* bridge 读端口 */
    input  wire [3:0]  i_rd_sel,            // 当前发送的框号（=bridge o_roi_id）
    output wire [7:0]  o_rd_data,           // 组合读
    input  wire        i_rd_rst,            // bridge 块起始：读地址清零
    input  wire        i_rd_inc             // bridge 每收 1 字节：读地址+1
);

    /* ---------------- 灰度：g = (R + 2G + B) >> 2 ---------------- */
    wire [9:0] w_gray = ({2'b0, i_pix_rgb[23:16]} +
                         {1'b0, i_pix_rgb[15:8], 1'b0} +
                         {2'b0, i_pix_rgb[7:0]}) >> 2;

    /* ---------------- 框快照坐标（toggle 时锁存） ---------------- */
    reg [11:0] r_x0 [0:N_BOX-1];
    reg [11:0] r_y0 [0:N_BOX-1];
    reg        r_en  [0:N_BOX-1];

    /* ---------------- 每框命中判定（组合） ----------------
     * 行命中：y0 <= y <= y0+31；列命中：x0 <= x <= x0+31 */
    wire        in_row [0:N_BOX-1];
    wire        in_col [0:N_BOX-1];
    wire        w_hit  [0:N_BOX-1];
    wire [9:0]  w_addr [0:N_BOX-1];

    genvar gk;
    generate
        for (gk = 0; gk < N_BOX; gk = gk + 1) begin : G_CAP
            wire [11:0] bx0 = r_x0[gk];
            wire [11:0] by0 = r_y0[gk];
            wire [11:0] dx  = i_pix_x - bx0;            // x<bx0 时下溢，被 in_col 掩
            wire [11:0] dy  = i_pix_y - by0;
            assign in_row[gk] = r_en[gk] && (i_pix_y >= by0) && (dy <= 12'd31);
            assign in_col[gk] = (i_pix_x >= bx0) && (dx <= 12'd31);
            assign w_hit[gk]  = in_row[gk] && in_col[gk];
            assign w_addr[gk] = {dy[4:0], dx[4:0]};     // dy*32 + dx（均 <32）
        end
    endgenerate

    /* ---------------- 每框 1KB 裁剪缓存 ---------------- */
    reg [7:0] buf0 [0:1023];
    reg [7:0] buf1 [0:1023];
    reg [7:0] buf2 [0:1023];
    reg [7:0] buf3 [0:1023];
    reg [7:0] buf4 [0:1023];
    reg [7:0] buf5 [0:1023];
    reg [7:0] buf6 [0:1023];
    reg [7:0] buf7 [0:1023];
    reg [7:0] buf8 [0:1023];
    reg [7:0] buf9 [0:1023];

    reg [N_BOX-1:0] r_captured;
    assign o_captured = r_captured;

    /* ---------------- 捕获写 + 完成标志 + 快照锁存（单块，无多驱动） ---- */
    integer ki;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_captured <= {N_BOX{1'b0}};
            for (ki = 0; ki < N_BOX; ki = ki + 1) begin
                r_x0[ki] <= 12'd0; r_y0[ki] <= 12'd0; r_en[ki] <= 1'b0;
            end
        end else if (i_box_toggle) begin
            /* 新框快照：锁存坐标、清全部捕获标志（帧 N+2 行流过时重捕获） */
            r_captured <= {N_BOX{1'b0}};
            for (ki = 0; ki < N_BOX; ki = ki + 1) begin
                r_x0[ki] <= i_box_xy[ki*48 + 36 +: 12];
                r_y0[ki] <= i_box_xy[ki*48 + 24 +: 12];
                r_en[ki] <= (i_box_xy[ki*48 + 36 +: 12] != 12'hFFF);
            end
        end else if (i_pix_valid) begin
            for (ki = 0; ki < N_BOX; ki = ki + 1) begin
                if (w_hit[ki] && !r_captured[ki]) begin
                    case (ki)
                        0: buf0[w_addr[ki]] <= w_gray;
                        1: buf1[w_addr[ki]] <= w_gray;
                        2: buf2[w_addr[ki]] <= w_gray;
                        3: buf3[w_addr[ki]] <= w_gray;
                        4: buf4[w_addr[ki]] <= w_gray;
                        5: buf5[w_addr[ki]] <= w_gray;
                        6: buf6[w_addr[ki]] <= w_gray;
                        7: buf7[w_addr[ki]] <= w_gray;
                        8: buf8[w_addr[ki]] <= w_gray;
                        default: buf9[w_addr[ki]] <= w_gray;
                    endcase
                end
                /* 行末统一判定：本行是框 ki 的第 32 行 -> 捕获完成 */
                if (in_row[ki] && (i_pix_y == r_y0[ki] + 12'd31) &&
                    (i_pix_x == IMG_W-1))
                    r_captured[ki] <= 1'b1;
            end
        end
    end

    /* ---------------- bridge 读端口（组合读，地址随 req 递增） ------- */
    reg [9:0] rd_addr;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            rd_addr <= 10'd0;
        else if (i_rd_rst)
            rd_addr <= 10'd0;
        else if (i_rd_inc)
            rd_addr <= rd_addr + 10'd1;
    end

    assign o_rd_data = (i_rd_sel == 4'd0) ? buf0[rd_addr] :
                       (i_rd_sel == 4'd1) ? buf1[rd_addr] :
                       (i_rd_sel == 4'd2) ? buf2[rd_addr] :
                       (i_rd_sel == 4'd3) ? buf3[rd_addr] :
                       (i_rd_sel == 4'd4) ? buf4[rd_addr] :
                       (i_rd_sel == 4'd5) ? buf5[rd_addr] :
                       (i_rd_sel == 4'd6) ? buf6[rd_addr] :
                       (i_rd_sel == 4'd7) ? buf7[rd_addr] :
                       (i_rd_sel == 4'd8) ? buf8[rd_addr] :
                                            buf9[rd_addr];

endmodule
