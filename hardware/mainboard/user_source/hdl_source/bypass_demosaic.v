`timescale 1ns / 1ns
/*****************************************************************
 bypass_demosaic —— DIAG(v12b): demosaic 旁路实验
 把 demosaic 输入(4xRAW8)直接铺成 4x灰度RGB 送 AWB。
 若灰度图行对齐完美 => 行错位实锤在 demosaic(再自研前端替换);
 若灰度图仍斜 => 上游问题(推翻现有推理)。
*****************************************************************/
module bypass_demosaic (
    input           I_clk,
    input           I_rst_n,
    input           I_tvalid,
    input           I_tuser,
    input           I_tlast,
    input  [31:0]   I_tdata,     // {P3,P2,P1,P0} 各 8bit
    output reg      O_tvalid,
    output reg      O_tuser,
    output reg      O_tlast,
    output reg [95:0] O_tdata    // 4 x {R,G,B} 灰度
);
    reg        v_d, u_d, l_d;
    reg [31:0] d_d;
    wire [7:0] p0 = d_d[7:0],  p1 = d_d[15:8];
    wire [7:0] p2 = d_d[23:16], p3 = d_d[31:24];
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            v_d <= 0; u_d <= 0; l_d <= 0; d_d <= 0;
            O_tvalid <= 0; O_tuser <= 0; O_tlast <= 0; O_tdata <= 0;
        end else begin
            v_d <= I_tvalid; u_d <= I_tuser; l_d <= I_tlast; d_d <= I_tdata;
            O_tvalid <= v_d; O_tuser <= u_d; O_tlast <= l_d;
            O_tdata <= {p3,p3,p3, p2,p2,p2, p1,p1,p1, p0,p0,p0};
        end
    end
endmodule
