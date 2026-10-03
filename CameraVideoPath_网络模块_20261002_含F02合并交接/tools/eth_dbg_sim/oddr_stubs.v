/* 仿真用 ODDR 行为 stub（按 TD sim_release/ph1p/ph1p_logic_hdio.v 语义建模：
 *   d0 = posedge 数据，d1 = negedge 数据，q 在对应沿更新）
 * 仅供 tools/eth_dbg_sim 两个冒烟测试使用；真实原语由 TD 提供。 */
`timescale 1ns/1ps
module PH1P_LOGIC_HD_ODDR #(
    parameter ASYNCRST = "ENABLE"
) (
    input  wire clk,
    input  wire rst,
    input  wire d1,     // negedge 数据
    input  wire d0,     // posedge 数据
    output reg  q
);
    always @(posedge clk or posedge rst or negedge clk) begin
        if (rst)      q <= 1'b0;
        else if (clk) q <= d0;   // posedge
        else          q <= d1;   // negedge
    end
endmodule
