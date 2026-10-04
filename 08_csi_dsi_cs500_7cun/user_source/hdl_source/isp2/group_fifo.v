`timescale 1ns / 1ns
/*****************************************************************
 group_fifo —— 组缓冲(v13b): 吸收 raw10 行突发, 平滑供 cvp_proc 齿轮箱
 根因: cvp_proc 齿轮箱 4 拍/组, 而 raw10 解包输出为行突发(突发段背靠背
 每拍 1 组), 突发段齿轮箱大量丢组(实测吞吐 3/8)。
 本模块: 42bit(40 数据+tuser+tlast) x 1024 同钟 FIFO(二进制指针, 空判决
 无保守延迟), 写=上游突发, 读=FIFO 非空即连续读(齿轮箱全速弹, 能力
 40.2M/4=10M 组/s >> 平均 3.07M; 行静默段清空积压, 稳态平衡)。
 读时序: rd_en(T) -> rd_valid/rd_data(T+1), 与齿轮箱 i_grp_* 直接对接。
*****************************************************************/
module group_fifo (
    input          I_clk,
    input          I_rst_n,

    input          I_wr_valid,
    input  [39:0]  I_wr_data,
    input          I_wr_tuser,
    input          I_wr_tlast,

    output wire        O_rd_valid,
    output wire [39:0] O_rd_data,
    output wire        O_rd_tuser,
    output wire        O_rd_tlast
);

    reg [41:0] mem [0:1023];
    reg [10:0] wptr, rptr;
    wire       full  = ((wptr - rptr) == 11'd1024);
    wire       empty = (wptr == rptr);
    wire       rd_en = !empty;

    wire [10:0] wptr_n = wptr + {10'd0, (I_wr_valid && !full)};
    wire [10:0] rptr_n = rptr + {10'd0, rd_en};

    reg [41:0] rdata_r;
    reg        rvalid_r;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            wptr <= 11'd0;
            rptr <= 11'd0;
            rdata_r  <= 42'd0;
            rvalid_r <= 1'b0;
        end else begin
            wptr <= wptr_n;
            rptr <= rptr_n;
            if (I_wr_valid && !full)
                mem[wptr[9:0]] <= {I_wr_tuser, I_wr_tlast, I_wr_data};
            rvalid_r <= rd_en;
            if (rd_en)
                rdata_r <= mem[rptr[9:0]];
        end
    end

    assign O_rd_valid = rvalid_r;
    assign O_rd_data  = rdata_r[39:0];
    assign O_rd_tuser = rdata_r[40];
    assign O_rd_tlast = rdata_r[41];

endmodule
