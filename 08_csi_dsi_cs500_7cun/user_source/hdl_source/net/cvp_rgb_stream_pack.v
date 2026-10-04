`timescale 1ns / 1ns
/******************************* CAM CHECK *******************************
* Module Name: cvp_rgb_stream_pack
* Description: 把 ISP(AWB) 输出的 96bit 像素拍(4 个 RGB888,通道对齐:
*              [95:72]=像素0, [71:48]=像素1, [47:24]=像素2, [23:0]=像素3)
*              转成单像素流 (O_pix_valid / O_pix_rgb) 供 cvp_eth_dbg 使用。
* 设计要点:
*   - cvp_async_fifo(96bit x 1024) 吸收 ISP 行读出突发(每行 256 拍背靠背(1024 宽));
*   - 发送端为"预取槽 + 4 拍展开"流水; 注意所有时序寄存器只在下面唯一的
*     always 块中赋值(HDL-8007 多驱动), 且 FIFO 数据落下分支放在最后,
*     与"预取槽搬运到发送级"同拍发生时后写生效, 数据不丢、顺序不乱。
*************************************************************************/

module cvp_rgb_stream_pack (
    input  wire        I_clk,        // 像素时钟 (例程: S_csi_rx_clk)
    input  wire        I_rst_n,      // 低有效
    input  wire        I_tuser,      // 帧起始(未使用,预留)
    input  wire        I_tvalid,     // 96bit 拍有效
    input  wire [95:0] I_tdata,      // 4 个 RGB888 像素
    output reg         O_pix_valid,  // 单像素有效(每拍至多 1 个)
    output reg  [23:0] O_pix_rgb     // {R,G,B} —— 与屏幕显示字节序一致
);

    /* ---------------- 96bit 拍级 FIFO, 吸收 ISP 行读出突发 ---------------- */
    wire        w_fifo_rd;
    wire        w_fifo_empty;

    /* ---- 内嵌同钟 FIFO(96bit x 1024) ----
     * 为什么不用 cvp_async_fifo: 其 Gray 指针空判决带 2 拍同步保守量,
     * 本模块"读一拍、展开五拍、追空再等"的使用模式会被拖成 ~10 拍/输入拍
     * -> 实测吞恰好减半(50%), 与上板抓包 50.2% 完全复现(联合逐拍模拟 50.4%)。
     * 同钟二进制指针空判决无延迟, 追空后 1 拍即可恢复读取。
     * 读时序与原 FIFO 相同: rd_en(T) -> rd_valid/rd_data(T+1)。 */
    reg [95:0] beat_mem [0:1023];
    reg [10:0] b_wptr, b_rptr;
    reg [95:0] w_fifo_data;
    reg        w_fifo_valid;

    wire        w_beat_full  = ((b_wptr - b_rptr) == 11'd1024);
    wire [10:0] w_b_wptr_n   = b_wptr + {10'd0, (I_tvalid && !w_beat_full)};
    wire [10:0] w_b_rptr_n   = b_rptr + {10'd0, (w_fifo_rd && !w_fifo_empty)};

    assign w_fifo_empty = (b_wptr == b_rptr);   // 组合判决: 写入后下拍解除

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            b_wptr      <= 11'd0;
            b_rptr      <= 11'd0;
            w_fifo_data <= 96'd0;
            w_fifo_valid<= 1'b0;
        end else begin
            b_wptr <= w_b_wptr_n;
            b_rptr <= w_b_rptr_n;
            if (I_tvalid && !w_beat_full)
                beat_mem[b_wptr[9:0]] <= I_tdata;
            w_fifo_valid <= w_fifo_rd && !w_fifo_empty;
            if (w_fifo_rd && !w_fifo_empty)
                w_fifo_data <= beat_mem[b_rptr[9:0]];
        end
    end

    /* ---------------- 时序寄存器(全部只在下方唯一的 always 中赋值) ---------------- */
    reg [95:0] r_next;      // 预取槽: FIFO 已读出、待装入发送级的一拍
    reg        r_next_v;
    reg [95:0] r_beat;      // 发送级: 正在展开的一拍
    reg        r_beat_v;
    reg [1:0]  r_sel;       // 当前展开的 lane (0=[95:72] 最先)
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
            O_pix_valid <= 1'b0;
            O_pix_rgb   <= 24'd0;
        end else begin
            O_pix_valid <= 1'b0;

            // (a) 发送级展开: 每拍按 lane 顺序发 1 个像素
            if (r_beat_v) begin
                O_pix_valid <= 1'b1;
                case (r_sel)
                    2'd0:    O_pix_rgb <= r_beat[95:72];
                    2'd1:    O_pix_rgb <= r_beat[71:48];
                    2'd2:    O_pix_rgb <= r_beat[47:24];
                    default: O_pix_rgb <= r_beat[23:0];
                endcase
                if (r_sel == 2'd3)
                    r_beat_v <= 1'b0;
                r_sel <= r_sel + 2'd1;
            end else if (r_next_v) begin
                // 发送级空、预取槽有数据: 装入(读到的是旧 r_next 值, 正确)
                r_beat   <= r_next;
                r_beat_v <= 1'b1;
                r_sel    <= 2'd0;
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
