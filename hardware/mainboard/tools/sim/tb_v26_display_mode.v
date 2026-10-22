`timescale 1ns/1ps
// Exercise real configuration commits and the complete style/OSD pipeline.
module tb_v26_display_mode;
 reg clk=0,cfg_clk=0,net_clk=0,rst=0,v=0,sof=0,group_valid=0,command_valid=0;
 always #5 clk=~clk;always #21 cfg_clk=~cfg_clk;always #4 net_clk=~net_clk;
 reg [15:0] req=0,cid=0;reg [7:0] op=0;reg [31:0] value=0;
 reg [1:0] keys=3;
 wire ov,oe;wire [2:0] display_mode;integer completed=0,old_completed,m,p;
 cvp_advanced #(.W(32),.H(16),.V27(1)) dut(
  .clk(clk),.rst_n(rst),.i_capture_valid(group_valid),.i_capture_event(v&&sof),.keys_n(keys),
  .i_valid(v),.i_sof(sof),.i_rgb(24'h806040),
  .cmd_valid(command_valid),.cmd_req(req),.cmd_cfg(cid),.cmd_op(op),.cmd_addr(8'd0),.cmd_value(value),
  .legacy_valid(1'b0),.legacy_cmd(8'd0),.legacy_value(24'd0),
  .cfg_clk(cfg_clk),.i_cam_done(1'b1),.i_ae_done(1'b1),.i_iic_error(1'b0),.i_cfg_error(1'b0),
  .o_valid(ov),.o_eof(oe),.o_display_mode(display_mode),.status_ready(1'b1),.i_sensor_diagnostics(128'd0),
  .i_net_overflow(1'b0),.i_net_tx_done(1'b0),.i_net_tx_fid(32'd0),.net_clk(net_clk),.net_rst_n(rst),
  .result_done_tick(64'd0),.result_valid(1'b0),.result_frame(32'd0),.result_roi(16'd0),
  .result_class(8'd0),.result_bbox(64'd0),.result_score(32'd0),.result_format(7'd0));
 defparam dut.keys.DEBOUNCE=4;
 always @(negedge clk)if(rst&&ov&&oe)completed=completed+1;
 task send(input [7:0] operation,input [31:0] data);
 begin
  @(negedge clk);req=req+1;op=operation;value=data;command_valid=1;
  @(negedge clk);command_valid=0;
 end
 endtask
 task frame(input integer wanted);
 begin
  old_completed=completed;
  for(p=0;p<512;p=p+1)begin
   @(negedge clk);v=1;sof=p==0;group_valid=p%4==0;
  end
  @(negedge clk);v=0;sof=0;group_valid=0;
  repeat(3000)@(negedge clk);
  if(completed!=old_completed+1||display_mode!==wanted)
   $fatal(1,"completed video mode mismatch wanted=%0d actual=%0d frames=%0d",wanted,display_mode,completed);
 end
 endtask
 task press(input integer key);
 begin
  @(negedge clk);keys[key]=0;repeat(20)@(negedge clk);
  keys[key]=1;repeat(20)@(negedge clk);
 end
 endtask
 initial begin
  repeat(8)@(negedge clk);rst=1;repeat(50)@(negedge clk);
  if(display_mode!==0)$fatal(1,"mode must reset to original");
  for(m=0;m<8;m=m+1)begin
   cid=m+1;send(1,m%7);send(2,0);repeat(8)@(negedge clk);
   if(display_mode!==(m==0?0:(m-1)%7))$fatal(1,"uncommitted mode must not replace completed video mode");
   frame(m%7);
  end
  // KEY3 increments 0->1->...->6->0, KEY2 decrements 0->6->...->0.
  for(m=1;m<=7;m=m+1)begin
   press(1);
   if(display_mode!==(m-1)%7)$fatal(1,"KEY3 changed mode before a video frame completed");
   frame(m%7);
  end
  for(m=1;m<=7;m=m+1)begin
   press(0);
   if(display_mode!==(8-m)%7)$fatal(1,"KEY2 changed mode before a video frame completed");
   frame((7-m)%7);
  end
  $display("TEST_RESULT PASS actual_video_display_mode 0..6 and return0 KEY3_increment_KEY2_decrement wrap frame-completion synchronization");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
