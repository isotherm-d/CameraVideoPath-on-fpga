`timescale 1 ns / 1 ps
/*=============================================================================
 * EG_LOGIC_FIFO 功能级仿真替代模型
 *
 * TD5.6 sim_release/eg/eg_logic_fifo.v 是空壳("TO BE FILLED", 标志恒 X),
 * 本文件提供同名功能模型: 异步 FIFO, 双向 gray 指针同步, AF/AE 阈值,
 * 空读/满写忽略(指针不前进, 与硬 FIFO 行为一致)。
 * 仅用于 tools/sim 仿真(编入 lib_ddr 覆盖空壳), 不参与综合。
 * 语义: afull 在占用 ≥ AF+1 拉高; aempty 在占用 ≤ AE 拉高;
 *       empty 在占用 = 0 拉高; full 在占用 = 深度 拉高。
 *===========================================================================*/
`timescale 1 ns / 1 ps
module EG_LOGIC_FIFO #(
    parameter DATA_WIDTH_W = 9,
    parameter DATA_WIDTH_R = DATA_WIDTH_W,
    parameter DATA_DEPTH_W = 1024,                  // 写侧字数
    parameter DATA_DEPTH_R = DATA_WIDTH_W * DATA_DEPTH_W / DATA_WIDTH_R,
    parameter MODE = "FIFO8K",
    parameter REGMODE_W = "NOREG",
    parameter REGMODE_R = "NOREG",
    parameter E = 0,
    parameter AE = 6,
    parameter AF = DATA_DEPTH_W-6,
    parameter F = DATA_DEPTH_W,
    parameter GSR = "DISABLE",
    parameter RESETMODE = "ASYNC",
    parameter ASYNC_RESET_RELEASE = "SYNC",
    parameter ENDIAN = "LITTLE"
)(
    input                     rst,
    input  [DATA_WIDTH_W-1:0] di,
    input                     clkw,
    input                     we,
    input  [2:0]              csw,
    output reg [DATA_WIDTH_R-1:0] do,
    input                     clkr,
    input                     re,
    input  [2:0]              csr,
    input                     ore,
    output reg                empty_flag,
    output reg                aempty_flag,
    output reg                full_flag,
    output reg                afull_flag
);
    localparam AW = $clog2(DATA_DEPTH_W) + 1;       // 指针位宽(含回绕位)

    reg [DATA_WIDTH_W-1:0] mem [0:DATA_DEPTH_W-1];
    reg [AW-1:0] wptr = 0;                          // 写指针(二进制+回绕位)
    reg [AW-1:0] rptr = 0;                          // 读指针

    /* 跨域同步: 写指针 → 读域, 读指针 → 写域 (gray, 2 级) */
    reg [AW-1:0] wptr_g = 0, wptr_gs1 = 0, wptr_gs2 = 0;
    reg [AW-1:0] rptr_g = 0, rptr_gs1 = 0, rptr_gs2 = 0;
    always @(posedge clkw) begin
        wptr_g   <= (wptr >> 1) ^ wptr;
        rptr_gs1 <= rptr_g;
        rptr_gs2 <= rptr_gs1;
    end
    always @(posedge clkr) begin
        rptr_g   <= (rptr >> 1) ^ rptr;
        wptr_gs1 <= wptr_g;
        wptr_gs2 <= wptr_gs1;
    end
    function [AW-1:0] g2b(input [AW-1:0] g);
        integer j;
        begin
            g2b[AW-1] = g[AW-1];
            for (j = AW-2; j >= 0; j = j - 1)
                g2b[j] = g2b[j+1] ^ g[j];
        end
    endfunction
    wire [AW-1:0] wptr_r = g2b(wptr_gs2);           // 写指针@读域
    wire [AW-1:0] rptr_w = g2b(rptr_gs2);           // 读指针@写域

    wire [AW:0]   occ_w = {1'b0, wptr} - {1'b0, rptr_w};
    wire [AW:0]   occ_r = {1'b0, wptr_r} - {1'b0, rptr};

    /* 写域: 写内存 + 写侧标志 */
    always @(posedge clkw or posedge rst) begin
        if (rst) begin
            wptr      <= 0;
            afull_flag <= 1'b0;
            full_flag  <= 1'b0;
        end else begin
            if (we && occ_w < DATA_DEPTH_W) begin
                mem[wptr[AW-2:0]] <= di;
                wptr <= wptr + 1'b1;
            end
            afull_flag <= (occ_w >= AF + 1);
            full_flag  <= (occ_w >= DATA_DEPTH_W);
        end
    end

    /* 读域: 读数据(空读保持, 指针不动) + 读侧标志 */
    always @(posedge clkr or posedge rst) begin
        if (rst) begin
            rptr       <= 0;
            do         <= {DATA_WIDTH_R{1'b0}};
            empty_flag  <= 1'b1;
            aempty_flag <= 1'b1;
        end else begin
            if (re && occ_r > 0) begin
                do   <= mem[rptr[AW-2:0]];
                rptr <= rptr + 1'b1;
            end
            empty_flag  <= (occ_r == 0);
            aempty_flag <= (occ_r <= AE);
        end
    end

endmodule
