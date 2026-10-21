module cvp_luma_pack(input clk,rst_n,i_valid,i_sof,input [23:0] i_rgb,
 output reg o_valid,o_sof,output reg [31:0] o_pixel);
 wire [17:0] r={10'd0,i_rgb[23:16]},g={10'd0,i_rgb[15:8]},b={10'd0,i_rgb[7:0]};
 reg [17:0] rr,gg,bb;reg [23:0] rgb1;reg v1,s1;
 wire [17:0] sum=rr+gg+bb+18'd128;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin rr<=0;gg<=0;bb<=0;rgb1<=0;v1<=0;s1<=0;o_valid<=0;o_sof<=0;o_pixel<=0;end
  else begin
   rr<=((r<<6)+(r<<3))+((r<<2)+r);
   gg<=((g<<7)+(g<<4))+((g<<2)+(g<<1));
   bb<=((b<<4)+(b<<3))+((b<<2)+b);
   rgb1<=i_rgb;v1<=i_valid;s1<=i_valid&&i_sof;
   o_pixel<={sum[15:8],rgb1};o_valid<=v1;o_sof<=v1&&s1;
  end
 end
endmodule
