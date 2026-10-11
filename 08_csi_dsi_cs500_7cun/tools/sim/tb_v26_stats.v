`timescale 1ns/1ps
module tb_v26_stats;
 reg clk=0,rst=0,v=0,sof=0,eof=0;reg [23:0] rgb=0,raw=0;
 always #5 clk=~clk;
 wire done,overrun;wire [7:0] mean,black,white;wire [10:0] r,g,b;wire [1:0] awb;
 wire [31:0] samples,neutrals,clipped;
 cvp_frame_stats #(.W(16),.H(8)) dut(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_eof(eof),
 .i_rgb(rgb),.i_raw_rgb(raw),.i_awb_en(1'b1),.o_done(done),.o_mean(mean),.o_black(black),.o_white(white),
 .o_awb_r(r),.o_awb_g(g),.o_awb_b(b),.o_awb_state(awb),.o_samples(samples),.o_neutral(neutrals),.o_clipped(clipped),.o_stat_overrun(overrun));
 integer p,errors=0;reg [10:0] saved_r,saved_b;
 task frame;input [23:0] raw_value,corrected;
 begin
  for(p=0;p<128;p=p+1)begin
   @(negedge clk);v=1;sof=p==0;eof=p==127;raw=raw_value;rgb=corrected;
  end
  @(negedge clk);v=0;sof=0;eof=0;
  wait(done);@(negedge clk);
  if(samples!=128||overrun)errors=errors+1;
 end endtask
 initial begin
  #31;rst=1;#400;// LUTRAM直方图上电旋转清扫需>=32拍, 复位后须空等再驱帧
  frame({8'd75,8'd100,8'd57},{8'd101,8'd100,8'd100});
  if(mean!=100||neutrals!=128||awb!=1||g!=256||r<338||r>345||b<445||b>453)errors=errors+1;
  frame({8'd90,8'd100,8'd45},{8'd121,8'd100,8'd79});
  if(r>=344||b<=451||awb!=1)errors=errors+1;
  saved_r=r;saved_b=b;
  frame(24'hff0000,24'hc80000);
  if(neutrals!=0||awb!=2||r!=saved_r||b!=saved_b)errors=errors+1;
  frame(0,0);if(mean!=0||black!=0||white!=7||neutrals!=0)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS stats_first_last_and_awb_guards");
  else $display("TEST_RESULT FAIL stats %0d mean%0d neutral%0d gains%0d/%0d",errors,mean,neutrals,r,b);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
