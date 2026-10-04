`timescale 1ns / 1ns
/****************************** CAM CHECK *******************************
* Module Name: cvp_rgb_stream_pack
* Description: 把 ISP(AWB) 输出的 96bit 像素拍(4 个 RGB888,通道对齐:
*              [95:72]=像素0, [71:48]=像素1, [47:24]=像素2, [23:0]=像素3)
*              转成单像素流 (O_pix_valid / O_pix_rgb) 供 cvp_eth_dbg 使用。
* 设计要点:
*   - cvp_async_fifo(96bit x 1024) 吸收 ISP 行读出突发(每行 256 拍背靠背);
*   - **每个像素连续输出 3 拍**(同一 RGB 重复 3 次): cvp_eth_dbg 的字节化
*     逻辑对每个有效拍轮转 r_bsel 取 R/G/B 各一字节, 若每拍给新像素则
*     每 3 个像素只写 3 个字节 -> 帧数据量缩到 1/3、3 个真实帧拼成 1 个
*     假帧(帧率÷3 + 跨帧错位斜条纹), 这是 v3 及以前网口慢的根因;
*   - 吞吐: 每帧 614400 像素 x 3 拍 = 36.9M 拍/s, S_csi_rx_clk(2-lane
*     合并 byte 时钟)约 80MHz, 占空比 46%, 行末可清空 FIFO 积压;
*   - 注意所有时序寄存器只在唯一 always 块中赋值(HDL-8007 多驱动),
*     FIFO 数据落下分支放在最后, 与"预取槽搬运到发送级"同拍发生时
*     后写生效, 数据不丢、顺序不乱。
*************************************************************************/

module cvp_rgb_stream_pack (
    input  wire        I_clk,        // 像素时钟 (例程: S_csi_rx_clk)
    input  wire        I_rst_n,      // 低有效
    input  wire        I_tuser,      // 帧起始(未使用,预留)
    input  wire        I_tvalid,     // 96bit 拍有效
    input  wire [95:0] I_tdata,      // 4 个 RGB888 像素
    output reg         O_pix_valid,  // 单像素有效(每像素连续 3 拍)
    output reg  [23:0] O_pix_rgb     // {R,G,B} —— 3 拍保持不变
);

    /* ---------------- 96bit 拍级 FIFO, 吸收 ISP 行读出突发 ---------------- */
    wire        w_fifo_rd;
    wire        w_fifo_valid;     // FIFO 读出数据有效(读请求的下一拍)
    wire [95:0] w_fifo_data;
    wire        w_fifo_empty;

    cvp_async_fifo #(
        .DATA_WIDTH (96),
        .ADDR_WIDTH (10)          // 1024 拍, 大于单行 256 拍的突发量
    ) u_beat_fifo (
        .wr_clk   (I_clk),
        .wr_rst_n (I_rst_n),
        .wr_en    (I_tvalid),
        .wr_data  (I_tdata),
        .wr_full  (),
        .wr_level (),
        .wr_flush (1'b0),
        .rd_clk   (I_clk),
        .rd_rst_n (I_rst_n),
        .rd_en    (w_fifo_rd),
        .rd_data  (w_fifo_data),
        .rd_valid (w_fifo_valid),
        .rd_empty (w_fifo_empty),
        .rd_flush (1'b0)
    );

    /* ---------------- 时序寄存器(全部只在下方唯一的 always 中赋值) ---------------- */
    reg [95:0] r_next;      // 预取槽: FIFO 已读出、待装入发送级的一拍
    reg        r_next_v;
    reg [95:0] r_beat;      // 发送级: 正在展开的一拍
    reg        r_beat_v;
    reg [1:0]  r_sel;       // 当前展开的像素 (0=[95:72] 最先)
    reg [1:0]  r_sub;       // 同一像素内第 0..2 拍(3 拍重复输出)
    reg        r_pop;       // FIFO 读请求(寄存一拍)

    // 预取槽空着且 FIFO 读出上没有正在落下的数据时, 请求读一拍
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_pop <= 1'b0;
        else
            r_pop <= (!r_next_v) && (!w_fifo_valid) && (!w_fifo_empty);
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_next      <= 96'd0;
            r_next_v    <= 1'b0;
            r_beat      <= 96'd0;
            r_beat_v    <= 1'b0;
            r_sel       <= 2'd0;
            r_sub       <= 2'd0;
            O_pix_valid <= 1'b0;
            O_pix_rgb   <= 24'd0;
        end else begin
            O_pix_valid <= 1'b0;

            // (a) 发送级展开: 每像素 3 拍(O_pix_rgb 保持), eth_dbg 依次取 R/G/B
            if (r_beat_v) begin
                O_pix_valid <= 1'b1;
                case (r_sel)
                    2'd0:    O_pix_rgb <= r_beat[95:72];
                    2'd1:    O_pix_rgb <= r_beat[71:48];
                    2'd2:    O_pix_rgb <= r_beat[47:24];
                    default: O_pix_rgb <= r_beat[23:0];
                endcase
                if (r_sub == 2'd2) begin
                    r_sub <= 2'd0;
                    r_sel <= r_sel + 2'd1;
                    if (r_sel == 2'd3)
                        r_beat_v <= 1'b0;
                end else begin
                    r_sub <= r_sub + 2'd1;
                end
            end else if (r_next_v) begin
                // 发送级空、预取槽有数据: 装入(读到的是旧 r_next 值, 正确)
                r_beat   <= r_next;
                r_beat_v <= 1'b1;
                r_sel    <= 2'd0;
                r_sub    <= 2'd0;
                r_next_v <= 1'b0;
            end

            // (b) FIFO 数据落下 -> 预取槽(放在最后: 与 (a) 的装入同拍发生时,
            //     后写生效, 新数据保留在预取槽, 不丢不乱)
            if (w_fifo_valid) begin
                r_next_v <= 1'b1;
                r_next   <= w_fifo_data;
            end
        end
    end

    assign w_fifo_rd = r_pop;

endmodule
