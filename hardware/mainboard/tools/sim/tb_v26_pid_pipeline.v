`timescale 1ns/1ps
module tb_v26_pid_pipeline;
 reg clk=0,cc=0,nc=0,rst=0,v=0,sof=0,group_valid=0,ae_done=1;
 always #5 clk=~clk;always #21 cc=~cc;always #4 nc=~nc;
 reg cmdv=0;reg [7:0] op=0,addr=0;reg [31:0] value=0;
 reg [23:0] input_rgb=0;integer light=40,physical_exp=500,physical_pending=500,physical_delay=0;
 integer sensor_transactions=0;
 wire sensor_req;wire [15:0] se,sg;wire ov,os,oe;wire [23:0] rgb;wire [31:0] fid;
 wire cv,cs,cl,ce;wire [23:0] crgb;wire [11:0] cx,cy;wire [31:0] cf;wire [15:0] cfg;wire [127:0] cp;
 wire [1535:0] st;wire sv;wire [63:0] ticks;integer sensor_count=0;
 cvp_advanced #(.W(16),.H(8),.V27(1)) dut(.clk(clk),.rst_n(rst),.i_capture_valid(group_valid),.i_capture_event(v&&sof),.keys_n(2'b11),
 .i_valid(v),.i_sof(sof),.i_rgb(input_rgb),.cmd_valid(cmdv),.cmd_req(16'd1),.cmd_cfg(16'd1),
 .cmd_op(op),.cmd_addr(addr),.cmd_value(value),.legacy_valid(1'b0),.legacy_cmd(8'd0),.legacy_value(24'd0),
 .cfg_clk(cc),.i_cam_done(1'b1),.i_ae_done(ae_done),.i_iic_error(1'b0),.i_cfg_error(1'b0),
 .sensor_req(sensor_req),.sensor_exp_cfg(se),.sensor_gain_cfg(sg),
 .o_valid(ov),.o_sof(os),.o_eof(oe),.o_rgb(rgb),.o_frame_id(fid),
 .status_data(st),.status_valid(sv),.status_ready(1'b1),.i_sensor_diagnostics(128'd0),.i_net_overflow(1'b0),.i_net_tx_done(1'b0),.i_net_tx_fid(32'd0),.net_clk(nc),.net_rst_n(rst),
 .clean_valid(cv),.clean_sof(cs),.clean_eol(cl),.clean_eof(ce),.clean_rgb(crgb),.clean_x(cx),.clean_y(cy),.clean_frame_id(cf),.clean_cfg_id(cfg),.clean_pixel(cp),
 .time_ticks(ticks),.result_done_tick(64'd0),.result_valid(1'b0),.result_ready(),.result_frame(32'd0),.result_roi(16'd0),.result_class(8'd0),
 .result_bbox(64'd0),.result_score(32'd0),.result_format(7'd0));
 integer f,p,errors=0,seen=0,nonzero=0,scene_first=0,first_dark=0;
 always @(posedge cc)begin
  if(sensor_req)begin
   ae_done<=0;sensor_count=20;sensor_transactions=sensor_transactions+1;
   physical_pending=se;physical_delay=2;
   if(sg!=108)begin errors=errors+1;$display("FAIL automatic analogue gain changed to %0d",sg);end
  end else if(sensor_count>0)begin sensor_count=sensor_count-1;if(sensor_count==0)ae_done<=1;end
 end
 always @(negedge clk)begin
  if(ov)begin
   seen=seen+1;if(rgb!=0)nonzero=nonzero+1;
   if(fid!==((seen-1)/128)||os!==((seen-1)%128==0)||oe!==((seen-1)%128==127))errors=errors+1;
  end
 end
 task command;input [7:0] operation,address;input [31:0] data;begin
  @(negedge clk);cmdv=1;op=operation;addr=address;value=data;
  @(negedge clk);cmdv=0;repeat(3)@(negedge clk);
 end endtask
 function [7:0] sat;input integer x;begin sat=x>255?255:x;end endfunction
 task image;integer y;begin
  if(physical_delay>0)begin
   physical_delay=physical_delay-1;if(physical_delay==0)physical_exp=physical_pending;
  end
  y=light*physical_exp/500;
  input_rgb={sat(y*75/100),sat(y),sat(y*57/100)};
  for(p=0;p<128;p=p+1)begin
   @(negedge clk);v=1;sof=p==0;group_valid=p%4==0;
   if(p%4==3)begin @(negedge clk);v=0;sof=0;group_valid=0;end
  end
  @(negedge clk);v=0;sof=0;group_valid=0;repeat(400)@(negedge clk);
 end endtask
 initial begin
  #31;rst=1;wait(!dut.sensor_busy);repeat(40)@(negedge clk);
  // No host command: power-on AE must drive the real sensor/gain/stats loop.
  if(dut.cfg_ae_en!==1||dut.cfg_wb_mode!==0||dut.cfg_id!==0||dut.selected_r!==344||dut.selected_g!==256||dut.selected_b!==451)
   $fatal(1,"power-on automatic exposure/calibrated WB defaults not active");
  for(f=0;f<140;f=f+1)begin image();if(dut.mean>=104&&dut.mean<=120&&first_dark==0)first_dark=f+1;end
  if(first_dark==0||first_dark>100||dut.mean<104||dut.mean>120||dut.digital_gain!=256||dut.sensor_gain!=108)errors=errors+1;
  $display("PIPELINE dark frames=%0d E=%0d DG=%0d mean=%0d",first_dark,dut.sensor_exp,dut.digital_gain,dut.mean);
  light=10;scene_first=0;
  for(f=0;f<160;f=f+1)begin image();if(dut.mean>=104&&dut.mean<=120&&scene_first==0)scene_first=f+1;end
  if(scene_first==0||dut.sensor_exp!=1800||dut.digital_gain<=256||dut.mean<104||dut.mean>120)errors=errors+1;
  $display("PIPELINE very_dark frames=%0d E=%0d DG=%0d mean=%0d",scene_first,dut.sensor_exp,dut.digital_gain,dut.mean);
  light=160;scene_first=0;
  for(f=0;f<160;f=f+1)begin image();if(dut.mean>=104&&dut.mean<=120&&scene_first==0)scene_first=f+1;end
  if(scene_first==0||dut.digital_gain!=256||dut.mean<104||dut.mean>120)errors=errors+1;
  $display("PIPELINE bright frames=%0d E=%0d DG=%0d mean=%0d",scene_first,dut.sensor_exp,dut.digital_gain,dut.mean);
  if(errors==0&&seen==460*128&&nonzero==seen&&!dut.fault&&dut.stream_errors==0&&sensor_transactions>1)
   $display("TEST_RESULT PASS actual_PID_sensor_bridge_SOF_gain_stats_stream_pipeline power_on_no_host_command frames=%0d transactions=%0d",seen/128,sensor_transactions);
  else $display("TEST_RESULT FAIL PID pipeline errors=%0d seen=%0d nonzero=%0d fault=%b stream=%0d",errors,seen,nonzero,dut.fault,dut.stream_errors);
  $finish;
 end
 initial begin #10000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
