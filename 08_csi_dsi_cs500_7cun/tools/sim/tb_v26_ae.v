`timescale 1ns/1ps
module tb_v26_ae;
 reg clk=0,rst=0,done=0,en=1;reg [7:0] mean=70,gain=108;reg [15:0] exp=500;
 always #5 clk=~clk;
 wire request;wire [15:0] desired;wire [7:0] dg;
 cvp_ae_control dut(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),.i_ready(1'b1),.i_busy(1'b0),
 .i_mean(mean),.i_clipped(32'd0),.i_samples(32'd128),.i_exp(exp),.i_gain(gain),.o_valid(request),.o_exp(desired),.o_gain(dg));
 integer n,events=0,errors=0;
 always @(negedge clk)if(request)begin
  if(mean<104&&desired<=exp&&dg<=gain)errors=errors+1;
  if(mean>120&&desired>=exp&&dg>=gain)errors=errors+1;
  if(desired<62||desired>1800||dg<16||dg>143)errors=errors+1;
  exp=desired;gain=dg;events=events+1;
 end
 task frames;input integer number;begin
  for(n=0;n<number;n=n+1)begin @(negedge clk);done=1;@(negedge clk);done=0;repeat(12)@(negedge clk);end
 end endtask
 initial begin
  #31;rst=1;frames(12);if(events<2||exp<=500)errors=errors+1;
  mean=180;frames(12);if(gain>=108)errors=errors+1;
  mean=112;events=0;frames(12);if(events!=0)errors=errors+1;
  en=0;mean=0;frames(8);if(events!=0)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS ae_direction_settle_and_manual");else $display("TEST_RESULT FAIL ae %0d exp%0d",errors,exp);
  $finish;
 end
endmodule
