/*
 * ============================================================================
 * cvp_async_fifo —— 参数化异步 FIFO（自研）
 *
 * 用途：在本工程的三个跨时钟域位置做数据缓冲
 *   1) 像素处理时钟(clk_100m) → DDR 时钟(ddr_clk) 的帧写数据；
 *   2) DDR 时钟(ddr_clk)      → HDMI 像素时钟(clk_pixel) 的帧读数据；
 *   3) 需要时做通用 CDC 缓冲。
 *
 * 实现要点（经典 Gray 指针方案）：
 *   - 写指针/读指针用二进制计数，同时保存一份 Gray 码；
 *   - Gray 码跨时钟域打两拍同步，避免多 bit 同时变化造成的亚稳态错误；
 *   - full  = 写指针 Gray 追到读指针 Gray 的反转最高两位；
 *   - empty = 读指针 Gray 追到同步过来的写指针 Gray。
 *   - 读数据寄存一拍输出，rd_valid 表示 rd_data 有效。
 *
 * 深度必须是 2 的幂：DEPTH = 2^ADDR_WIDTH。
 * 本工程使用：DATA_WIDTH=128, ADDR_WIDTH=9（512 x 128bit）。
 * ============================================================================
 */
module cvp_async_fifo #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 9
) (
    /* ---- 写时钟域 ---- */
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg                   wr_full,
    output wire [ADDR_WIDTH:0]   wr_level,   // 写侧看到的“FIFO 里现在有多少字”（用于按下游消费节流）
    input  wire                  wr_flush,   // 写侧复位指针（帧边界，丢掉残留）

    /* ---- 读时钟域 ---- */
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output reg                   rd_valid,
    output reg                   rd_empty,
    input  wire                  rd_flush    // 读侧复位指针（帧边界，丢掉残留）
);

    localparam DEPTH = (1 << ADDR_WIDTH);

    /* 双口 RAM 模型：写口在 wr_clk，读口在 rd_clk，TD 会推断成 ERAM/BRAM */
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    /* 指针：多一位用于区分“满/空” */
    reg [ADDR_WIDTH:0] wr_bin, wr_gray;
    reg [ADDR_WIDTH:0] rd_bin, rd_gray;

    /* 跨时钟域同步后的 Gray 指针 */
    reg [ADDR_WIDTH:0] rd_gray_sync1, rd_gray_sync2;
    reg [ADDR_WIDTH:0] wr_gray_sync1, wr_gray_sync2;

    /* 组合逻辑：下一个指针值 */
    wire [ADDR_WIDTH:0] wr_bin_next = wr_bin + (wr_en & ~wr_full);
    wire [ADDR_WIDTH:0] wr_gray_next;
    wire [ADDR_WIDTH:0] rd_bin_next = rd_bin + (rd_en & ~rd_empty);
    wire [ADDR_WIDTH:0] rd_gray_next;

    /* Gray → 二进制（用于在写域算水位） */
    reg  [ADDR_WIDTH:0] rd_bin_sync;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) rd_bin_sync <= 'd0;
        else begin
            rd_bin_sync[ADDR_WIDTH] <= rd_gray_sync2[ADDR_WIDTH];
            rd_bin_sync[ADDR_WIDTH-1:0] <= rd_bin_sync[ADDR_WIDTH:1] ^ rd_gray_sync2[ADDR_WIDTH-1:0];
        end
    end
    assign wr_level = wr_bin - rd_bin_sync;

    /* 二进制 → Gray */
    function [ADDR_WIDTH:0] bin2gray(input [ADDR_WIDTH:0] bin);
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction

    assign wr_gray_next = bin2gray(wr_bin_next);
    assign rd_gray_next = bin2gray(rd_bin_next);

    /* ------------------------------ 写侧 ------------------------------ */
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin   <= 'd0;
            wr_gray  <= 'd0;
            wr_full  <= 1'b0;
        end else begin
            if (wr_flush) begin
                wr_bin  <= 'd0;
                wr_gray <= 'd0;
                wr_full <= 1'b0;
            end else begin
                wr_bin  <= wr_bin_next;
                wr_gray <= wr_gray_next;
            /* 满：写指针比读指针多绕一圈（最高两位相反，其余相同） */
                wr_full <= (wr_gray_next == {~rd_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                              rd_gray_sync2[ADDR_WIDTH-2:0]});
            end
        end
    end

    always @(posedge wr_clk) begin
        if (wr_en && !wr_full)
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    /* 读指针 Gray 码同步到写时钟域（两级触发器） */
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_sync1 <= 'd0;
            rd_gray_sync2 <= 'd0;
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    /* ------------------------------ 读侧 ------------------------------ */
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin   <= 'd0;
            rd_gray  <= 'd0;
            rd_empty <= 1'b1;
        end else begin
            if (rd_flush) begin
                rd_bin   <= 'd0;
                rd_gray  <= 'd0;
                rd_empty <= 1'b1;
            end else begin
                rd_bin   <= rd_bin_next;
                rd_gray  <= rd_gray_next;
                /* 空：读指针与同步过来的写指针 Gray 码相同 */
                rd_empty <= (rd_gray_next == wr_gray_sync2);
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_data  <= 'd0;
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en && !rd_empty;
            if (rd_en && !rd_empty)
                rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
        end
    end

    /* 写指针 Gray 码同步到读时钟域（两级触发器） */
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_sync1 <= 'd0;
            wr_gray_sync2 <= 'd0;
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

endmodule
