module cvp_ae_control_v33_gold(
 input clk,rst_n,i_frame_done,i_en,i_ready,i_busy,
 input [7:0] i_mean,input [31:0] i_clipped,i_samples,
 input [15:0] i_exp,input [7:0] i_gain,
 output reg o_valid,output reg [15:0] o_exp,output reg [7:0] o_gain
);
 // Four fresh frames per decision. Writing the sensor invalidates the window;
 // discard two completed frames AFTER the bridge becomes idle, then collect.
 reg [1:0] frames,settle;
 reg f1,window_valid;reg [7:0] mean1;
 reg [31:0] clipped1,samples1;
 reg [9:0] mean_sum,window_mean;
 reg [33:0] clip_sum,sample_sum,window_samples;
 reg [38:0] window_scaled_clip;
 wire [9:0] next_mean=mean_sum+{2'd0,mean1};
 wire [33:0] next_clip=clip_sum+{2'd0,clipped1};
 wire [33:0] next_samples=sample_sum+{2'd0,samples1};
 // Compare sums directly: no averaging divider or rounding at thresholds.
 wire dark=window_mean<10'd416; // 4 * 104
 wire bright=window_mean>10'd480 || window_scaled_clip>{5'd0,window_samples};
 // About 3.125% exposure steps (formerly 12.5%); one half-line minimum.
 wire [15:0] step=(i_exp>>5)==0?16'd1:(i_exp>>5);
 wire [16:0] raised={1'b0,i_exp}+{1'b0,step};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin frames<=0;settle<=0;o_valid<=0;o_exp<=500;o_gain<=108;
   f1<=0;window_valid<=0;mean1<=0;clipped1<=0;samples1<=0;
   mean_sum<=0;clip_sum<=0;sample_sum<=0;
   window_mean<=0;window_samples<=0;window_scaled_clip<=0;end
  else begin
   f1<=i_frame_done&&i_en&&i_ready&&!i_busy;
   if(i_frame_done)begin
    mean1<=i_mean;clipped1<=i_clipped;samples1<=i_samples;
   end
   o_valid<=0;window_valid<=0;
   if(!i_en||!i_ready||i_busy)begin
    frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
    if(!i_en||!i_ready)settle<=0;
   end else begin
    if(f1)begin
     if(samples1==0||settle!=0)begin
      frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
      if(samples1!=0&&settle!=0)settle<=settle-1'b1;
     end else if(frames==3)begin
      window_mean<=next_mean;window_samples<=next_samples;
      window_scaled_clip<=({5'd0,next_clip}<<4)+({5'd0,next_clip}<<2);
      window_valid<=1;
      frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
     end else begin
      frames<=frames+1'b1;mean_sum<=next_mean;
      clip_sum<=next_clip;sample_sum<=next_samples;
     end
    end
    if(window_valid)begin
     o_exp<=i_exp;o_gain<=i_gain;
     if(bright)begin
      if(i_gain>16)begin o_gain<=i_gain>18?i_gain-2:16;o_valid<=1;settle<=2;end
      else if(i_exp>62)begin o_exp<=i_exp>(step+62)?i_exp-step:62;o_valid<=1;settle<=2;end
     end else if(dark)begin
      if(i_exp<1800)begin o_exp<=raised>1800?1800:raised[15:0];o_valid<=1;settle<=2;end
      else if(i_gain<143)begin o_gain<=i_gain<141?i_gain+2:143;o_valid<=1;settle<=2;end
     end
    end
   end
  end
 end
endmodule
