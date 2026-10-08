module cvp_ae_control(
 input clk,rst_n,i_frame_done,i_en,i_ready,i_busy,
 input [7:0] i_mean,input [31:0] i_clipped,i_samples,
 input [15:0] i_exp,input [7:0] i_gain,
 output reg o_valid,output reg [15:0] o_exp,output reg [7:0] o_gain
);
 reg [1:0] period;reg [1:0] settle;
 reg f1,f2,dark,bright,has_samples;reg [7:0] mean1;
 reg [36:0] scaled_clip;reg [31:0] samples1;
 wire [15:0] step=i_exp>>3;wire [16:0] raised={1'b0,i_exp}+step;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin period<=0;settle<=0;o_valid<=0;o_exp<=500;o_gain<=108;
   f1<=0;f2<=0;dark<=0;bright<=0;has_samples<=0;mean1<=0;scaled_clip<=0;samples1<=0;end
  else begin
   f1<=i_frame_done;f2<=f1;
   if(i_frame_done)begin
    mean1<=i_mean;scaled_clip<=({5'd0,i_clipped}<<4)+({5'd0,i_clipped}<<2);samples1<=i_samples;
   end
   if(f1)begin dark<=mean1<104;bright<=mean1>120||scaled_clip>{5'd0,samples1};has_samples<=samples1!=0;end
   o_valid<=0;
   if(!i_en)begin period<=0;settle<=0;end
   else if(f2)begin
    period<=period+1'b1;
    if(settle!=0)settle<=settle-1'b1;
    else if(period==3 && i_ready&&!i_busy && has_samples)begin
     o_exp<=i_exp;o_gain<=i_gain;
     if(bright)begin
      if(i_gain>16)begin o_gain<=i_gain>24?i_gain-8:16;o_valid<=1;settle<=2;end
      else if(i_exp>62)begin o_exp<=i_exp>(step+62)?i_exp-step:62;o_valid<=1;settle<=2;end
     end else if(dark)begin
      if(i_exp<1800)begin o_exp<=raised>1800?1800:raised[15:0];o_valid<=1;settle<=2;end
      else if(i_gain<143)begin o_gain<=i_gain<135?i_gain+8:143;o_valid<=1;settle<=2;end
     end
    end
   end
  end
 end
endmodule
