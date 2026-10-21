module cvp_gain11_v33_gold(input clk,rst_n,i_valid,i_sof,input [23:0] i_rgb,
 input [10:0] i_r,i_g,i_b,input i_swap,output reg o_valid,o_sof,output reg [23:0] o_rgb);
 wire [7:0] r=i_swap?i_rgb[7:0]:i_rgb[23:16],b=i_swap?i_rgb[23:16]:i_rgb[7:0];
 wire [19:0] rr=r*i_r+20'd128,gg=i_rgb[15:8]*i_g+20'd128,bb=b*i_b+20'd128;
 function [7:0] sat;input [19:0] x;begin sat=|x[19:16]?255:x[15:8];end endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin o_valid<=0;o_sof<=0;o_rgb<=0;end else begin
   o_valid<=i_valid;o_sof<=i_valid&&i_sof;o_rgb<={sat(rr),sat(gg),sat(bb)};
  end
 end
endmodule
