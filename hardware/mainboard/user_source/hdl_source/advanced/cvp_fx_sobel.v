module cvp_fx_sobel #(parameter IMG_W=1280,POST_FILTER=0)(
 input i_clk,i_rst_n,i_valid,i_frame_start,input [10:0] i_th_low,i_th_high,
 input [31:0] i_p00,i_p01,i_p02,i_p10,i_p11,i_p12,i_p20,i_p21,i_p22,
 output reg o_valid,o_frame_start,output reg [23:0] o_rgb,output reg [10:0] o_mag);
 reg [10:0] right1,left1,down1,up1;
 reg signed [11:0] gx2,gy2;
 reg [10:0] threshold1,threshold2;
 reg v1,v2,s1,s2;
 wire [11:0] ax=gx2[11]?-gx2:gx2,ay=gy2[11]?-gy2:gy2;
 wire [12:0] mag={1'b0,ax}+{1'b0,ay};
 always @(posedge i_clk or negedge i_rst_n)begin
  if(!i_rst_n)begin right1<=0;left1<=0;down1<=0;up1<=0;gx2<=0;gy2<=0;
   threshold1<=190;threshold2<=190;v1<=0;v2<=0;s1<=0;s2<=0;
   o_valid<=0;o_frame_start<=0;o_rgb<=0;o_mag<=0;end
  else begin
   right1<=i_p02[31:24]+{i_p12[31:24],1'b0}+i_p22[31:24];
   left1<=i_p00[31:24]+{i_p10[31:24],1'b0}+i_p20[31:24];
   down1<=i_p20[31:24]+{i_p21[31:24],1'b0}+i_p22[31:24];
   up1<=i_p00[31:24]+{i_p01[31:24],1'b0}+i_p02[31:24];
   gx2<=$signed({1'b0,right1})-$signed({1'b0,left1});
   gy2<=$signed({1'b0,down1})-$signed({1'b0,up1});
   threshold1<=i_th_high;threshold2<=threshold1;
   v1<=i_valid;v2<=v1;s1<=i_valid&&i_frame_start;s2<=v1&&s1;
   o_valid<=v2;o_frame_start<=v2&&s2;o_mag<=mag>2040?2040:mag[10:0];
   o_rgb<=mag>=threshold2?24'hffffff:24'd0;
  end
 end
endmodule
