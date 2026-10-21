// Optional display-only auto levels. Coefficients apply atomically at SOF.
module cvp_tone_v30_gold(
 input clk,rst_n,i_valid,i_sof,input [23:0] i_rgb,input i_en,
 input i_stats_done,input [7:0] i_black,i_white,
 output reg o_valid,o_sof,output reg [23:0] o_rgb
);
 reg [10:0] pending_gain,active_gain;reg signed [11:0] pending_offset,active_offset;
 reg start;reg [31:0] num,den;wire done;wire [31:0] q;
 reg [7:0] black;
 cvp_divider div(.clk(clk),.rst_n(rst_n),.start(start),.numerator(num),.denominator(den),.done(done),.quotient(q));
 wire [10:0] limited=q<128?128:q>512?512:q[10:0];
 wire [18:0] black_product=black*limited;
 wire [10:0] gain=i_sof?(i_en?pending_gain:11'd256):active_gain;
 wire signed [11:0] offset=i_sof?(i_en?pending_offset:12'sd0):active_offset;
 function [7:0] map;input [7:0] p;input [10:0] g;input signed [11:0] off;
 reg [19:0] prod;reg signed [20:0] z;begin
 prod=p*g+128;z=$signed({1'b0,prod[19:8]})+off;
 map=z<0?0:z>255?255:z[7:0];end endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin pending_gain<=256;active_gain<=256;pending_offset<=0;active_offset<=0;
   start<=0;num<=224;den<=224;black<=0;o_valid<=0;o_sof<=0;o_rgb<=0;end
  else begin
   start<=0;
   if(i_stats_done)begin
    if(i_white>i_black+24)begin num<=224;den<=i_white-i_black;black<=i_black;start<=1;end
    else begin pending_gain<=256;pending_offset<=0;end
   end
   if(done)begin pending_gain<=limited;pending_offset<=12'sd16-$signed({1'b0,black_product[18:8]});end
   if(i_valid&&i_sof)begin active_gain<=gain;active_offset<=offset;end
   o_valid<=i_valid;o_sof<=i_valid&&i_sof;
   o_rgb<={map(i_rgb[23:16],gain,offset),map(i_rgb[15:8],gain,offset),map(i_rgb[7:0],gain,offset)};
  end
 end
endmodule
