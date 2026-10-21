`timescale 1ns/1ps
module tb_v27_startup;
 reg clk=0,rst=0,cam=0,ae=0,v=0,s=0;wire ov,os;integer errors=0;
 always #5 clk=~clk;
 cvp_camera_gate dut(.clk(clk),.rst_n(rst),.i_cfg_done(cam),.i_ae_done(ae),.i_valid(v),.i_sof(s),.o_valid(ov),.o_sof(os));
 initial begin
  #31;rst=1;v=1;s=1;#1;if(ov)errors=errors+1;
  @(negedge clk);s=0;cam=1;ae=1;repeat(5)@(negedge clk);if(ov)errors=errors+1;
  s=1;#1;if(!ov||!os)errors=errors+1;
  @(negedge clk);s=0;ae=0;repeat(5)@(negedge clk);if(!ov||os)errors=errors+1;
  rst=0;#1;if(ov)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS startup_discards_partial_frames_and_keeps_runtime_video");
  else $display("TEST_RESULT FAIL startup errors%0d",errors);
  $finish;
 end
endmodule
