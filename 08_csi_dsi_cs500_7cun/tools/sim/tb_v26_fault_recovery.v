`timescale 1ns/1ps
module tb_v26_fault_recovery;
 reg clk=0,cc=0,nc=0,rst=0,v=0,sof=0,group_valid=0,ae_done=1;
 always #5 clk=~clk;always #21 cc=~cc;always #4 nc=~nc;
 wire sensor_req;wire [15:0] se,sg;wire ov,os,oe;wire [23:0] rgb;wire [31:0] fid;
 wire cv,cs,cl,ce;wire [23:0] crgb;wire [11:0] cx,cy;wire [31:0] cf;wire [15:0] cfg;wire [127:0] cp;
 wire [1535:0] st;wire sv;wire [63:0] ticks;integer sensor_count=0;
 cvp_advanced #(.W(16),.H(8),.V27(1)) dut(.clk(clk),.rst_n(rst),.i_capture_valid(group_valid),.i_capture_event(v&&sof),.keys_n(2'b11),
 .i_valid(v),.i_sof(sof),.i_rgb({8'd75,8'd100,8'd57}),.cmd_valid(1'b0),.cmd_req(16'd0),.cmd_cfg(16'd0),
 .cmd_op(8'd0),.cmd_addr(8'd0),.cmd_value(32'd0),.legacy_valid(1'b0),.legacy_cmd(8'd0),.legacy_value(24'd0),
 .cfg_clk(cc),.i_cam_done(1'b1),.i_ae_done(ae_done),.i_iic_error(1'b0),.i_cfg_error(1'b0),
 .sensor_req(sensor_req),.sensor_exp_cfg(se),.sensor_gain_cfg(sg),
 .o_valid(ov),.o_sof(os),.o_eof(oe),.o_rgb(rgb),.o_frame_id(fid),
 .status_data(st),.status_valid(sv),.status_ready(1'b1),.i_sensor_diagnostics(128'd0),.i_net_overflow(1'b0),.i_net_tx_done(1'b0),.i_net_tx_fid(32'd0),.net_clk(nc),.net_rst_n(rst),
 .clean_valid(cv),.clean_sof(cs),.clean_eol(cl),.clean_eof(ce),.clean_rgb(crgb),.clean_x(cx),.clean_y(cy),.clean_frame_id(cf),.clean_cfg_id(cfg),.clean_pixel(cp),
 .time_ticks(ticks),.result_done_tick(64'd0),.result_valid(1'b0),.result_ready(),.result_frame(32'd0),.result_roi(16'd0),.result_class(8'd0),
 .result_bbox(64'd0),.result_score(32'd0),.result_format(7'd0));
 wire old_valid,old_sof,old_eof;wire [23:0] old_rgb;wire [31:0] old_fid;
 cvp_advanced_v32_gold #(.W(16),.H(8),.V27(1)) reference(.clk(clk),.rst_n(rst),.i_capture_valid(group_valid),.i_capture_event(v&&sof),.keys_n(2'b11),
 .i_valid(v),.i_sof(sof),.i_rgb({8'd75,8'd100,8'd57}),.cmd_valid(1'b0),.cmd_req(16'd0),.cmd_cfg(16'd0),
 .cmd_op(8'd0),.cmd_addr(8'd0),.cmd_value(32'd0),.legacy_valid(1'b0),.legacy_cmd(8'd0),.legacy_value(24'd0),
 .cfg_clk(cc),.i_cam_done(1'b1),.i_ae_done(ae_done),.i_iic_error(1'b0),.i_cfg_error(1'b0),
 .sensor_req(),.sensor_exp_cfg(),.sensor_gain_cfg(),
 .o_valid(old_valid),.o_sof(old_sof),.o_eof(old_eof),.o_rgb(old_rgb),.o_frame_id(old_fid),
 .status_data(),.status_valid(),.status_ready(1'b1),.i_sensor_diagnostics(128'd0),.i_net_overflow(1'b0),.i_net_tx_done(1'b0),.i_net_tx_fid(32'd0),.net_clk(nc),.net_rst_n(rst),
 .clean_valid(),.clean_sof(),.clean_eol(),.clean_eof(),.clean_rgb(),.clean_x(),.clean_y(),.clean_frame_id(),.clean_cfg_id(),.clean_pixel(),
 .time_ticks(),.result_done_tick(64'd0),.result_valid(1'b0),.result_ready(),.result_frame(32'd0),.result_roi(16'd0),.result_class(8'd0),
 .result_bbox(64'd0),.result_score(32'd0),.result_format(7'd0));
 always @(posedge cc)begin
  if(sensor_req)begin ae_done<=0;sensor_count=20;end
  else if(sensor_count>0)begin sensor_count=sensor_count-1;if(sensor_count==0)ae_done<=1;end
 end
 integer f,p,errors=0,seen=0,clean=0,statuses=0;
 always @(negedge clk)begin
  if(cv)begin
   if(crgb!==24'h656464||cx!==clean%16||cy!==(clean%128)/16||cf!==clean/128||cp[23:0]!==crgb||cp[79:48]!==cf)errors=errors+1;
   clean=clean+1;
  end
  if(ov!==old_valid)errors=errors+1;
  if(ov)begin if({rgb,os,oe,fid}!=={old_rgb,old_sof,old_eof,old_fid})errors=errors+1; if(rgb!==24'h656464||fid!==seen/128||os!==(seen%128==0)||oe!==(seen%128==127))errors=errors+1;seen=seen+1;end
  if(sv)begin
   if(st[1023:992]!==32'h43563236)errors=errors+1;
   statuses=statuses+1;
  end
 end
 initial begin
  #31;rst=1;#400;// LUTRAM直方图上电旋转清扫需>=32拍, 复位后须空等再驱帧
  for(f=0;f<6;f=f+1)begin
   for(p=0;p<128;p=p+1)begin
    @(negedge clk);v=1;sof=p==0;group_valid=(p%4==0)&&!(f==0&&p==124);
    if(p%4==3)begin @(negedge clk);v=0;sof=0;group_valid=0;end
   end
   @(negedge clk);v=0;sof=0;group_valid=0;repeat(400)@(negedge clk);
  end
  if(errors==0&&seen==768&&clean==768&&statuses>=6&&!dut.fault&&dut.stream_errors==1&&dut.source_bad_groups==31&&dut.stream_history==1&&reference.fault&&reference.stream_errors==1)$display("TEST_RESULT PASS complete_pipeline_recovers_after_bad_capture_frame");
  else $display("TEST_RESULT FAIL advanced errors%0d clean%0d display%0d statuses%0d fault%0d",errors,clean,seen,statuses,dut.fault);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
