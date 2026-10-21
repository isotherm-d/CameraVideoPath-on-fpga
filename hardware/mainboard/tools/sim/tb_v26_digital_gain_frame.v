`timescale 1ns/1ps
module tb_v26_digital_gain_frame;
 reg clk=0,cc=0,nc=0,rst=0,v=0,sof=0,group_valid=0,ae_done=1;
 always #5 clk=~clk;always #21 cc=~cc;always #4 nc=~nc;
 wire sensor_req;wire [15:0] se,sg;wire ov,os,oe;wire [23:0] rgb;wire [31:0] fid;
 wire cv,cs,cl,ce;wire [23:0] crgb;wire [11:0] cx,cy;wire [31:0] cf;wire [15:0] cfg;wire [127:0] cp;
 wire [1535:0] st;wire sv;wire [63:0] ticks;integer sensor_count=0;reg allow_done=1,iic_error=0;integer transactions=0;
 cvp_advanced #(.W(16),.H(8),.V27(1)) dut(.clk(clk),.rst_n(rst),.i_capture_valid(group_valid),.i_capture_event(v&&sof),.keys_n(2'b11),
 .i_valid(v),.i_sof(sof),.i_rgb({8'd75,8'd100,8'd57}),.cmd_valid(1'b0),.cmd_req(16'd0),.cmd_cfg(16'd0),
 .cmd_op(8'd0),.cmd_addr(8'd0),.cmd_value(32'd0),.legacy_valid(1'b0),.legacy_cmd(8'd0),.legacy_value(24'd0),
 .cfg_clk(cc),.i_cam_done(1'b1),.i_ae_done(ae_done),.i_iic_error(iic_error),.i_cfg_error(1'b0),
 .sensor_req(sensor_req),.sensor_exp_cfg(se),.sensor_gain_cfg(sg),
 .o_valid(ov),.o_sof(os),.o_eof(oe),.o_rgb(rgb),.o_frame_id(fid),
 .status_data(st),.status_valid(sv),.status_ready(1'b1),.i_sensor_diagnostics(128'd0),.i_net_overflow(1'b0),.i_net_tx_done(1'b0),.i_net_tx_fid(32'd0),.net_clk(nc),.net_rst_n(rst),
 .clean_valid(cv),.clean_sof(cs),.clean_eol(cl),.clean_eof(ce),.clean_rgb(crgb),.clean_x(cx),.clean_y(cy),.clean_frame_id(cf),.clean_cfg_id(cfg),.clean_pixel(cp),
 .time_ticks(ticks),.result_done_tick(64'd0),.result_valid(1'b0),.result_ready(),.result_frame(32'd0),.result_roi(16'd0),.result_class(8'd0),
 .result_bbox(64'd0),.result_score(32'd0),.result_format(7'd0));
 always @(posedge cc)begin
  if(sensor_req)begin ae_done<=0;sensor_count=20;transactions=transactions+1;end
  else if(sensor_count>0&&allow_done)begin sensor_count=sensor_count-1;if(sensor_count==0)ae_done<=1;end
 end
 reg error_seen=0;integer digital_acks=0,manual_acks=0;
 integer f,p,errors=0,seen=0,clean=0,statuses=0;
 always @(posedge clk)if(dut.ae_apply_error)error_seen<=1;
 always @(posedge clk)begin #1;
  if(dut.ae_applied)begin
   if(dut.ae_applied_digital_only)begin
    digital_acks=digital_acks+1;
    if(dut.digital_gain!=512||dut.sensor_exp!=500)errors=errors+1;
   end else begin
    manual_acks=manual_acks+1;
    if(dut.digital_gain!=256)errors=errors+1;
   end
  end
 end
 task inject;input [15:0] ex;input [10:0] dg;begin
  force dut.ae_exp=ex;force dut.ae_gain=8'd108;force dut.ae_dgain=dg;
  force dut.ae_valid=1'b1;
 end endtask
 always @(negedge clk)begin
  if(cv)begin
   if(crgb!==((cf==0||cf>=4)?24'h656464:24'hcac8c9)||cx!==clean%16||cy!==(clean%128)/16||cf!==clean/128||cp[23:0]!==crgb||cp[79:48]!==cf)errors=errors+1;
   clean=clean+1;
  end
  if(ov)begin if(rgb!==((fid==0||fid>=4)?24'h656464:24'hcac8c9)||fid!==seen/128||os!==(seen%128==0)||oe!==(seen%128==127))errors=errors+1;seen=seen+1;end
  if(sv)begin
   if(st[1023:992]!==32'h43563236||st[965])errors=errors+1;
   statuses=statuses+1;
  end
 end
 initial begin
  force dut.ae_valid=1'b0;
  #31;rst=1;wait(!dut.sensor_busy);repeat(40)@(negedge clk);
  for(f=0;f<6;f=f+1)begin
   for(p=0;p<128;p=p+1)begin
    @(negedge clk);force dut.ae_valid=1'b0;v=1;sof=p==0;group_valid=p%4==0;
    if(f==0&&p==40)inject(500,512);
    if(f==1&&p==40)begin allow_done=0;inject(600,768);end
    if(p%4==3)begin @(negedge clk);v=0;sof=0;group_valid=0;end
   end
   @(negedge clk);v=0;sof=0;group_valid=0;
   if(f==0&&transactions!=1)errors=errors+1; // digital-only request does not write I2C
   if(f==2)begin
    iic_error=1;allow_done=1;wait(!dut.sensor_busy);repeat(4)@(negedge clk);
    if(!error_seen||dut.digital_gain!=512||dut.sensor_exp!=500)errors=errors+1;
   end
   if(f==3)begin
    iic_error=0;
    force dut.manual_exp=16'd500;force dut.manual_gain=8'd108;force dut.manual_valid=1'b1;
    @(negedge clk);force dut.manual_valid=1'b0;
    wait(!dut.sensor_busy);repeat(40)@(negedge clk);
   end
   repeat(400)@(negedge clk);
  end
  if(st[1055:1040]!=256||st[1031:1024]!=8'hae)errors=errors+1;
  if(errors==0&&seen==768&&clean==768&&!dut.fault&&transactions==3&&dut.sensor_errors==1&&digital_acks==1&&manual_acks==1)
   $display("TEST_RESULT PASS digital_gain_SOF_atomic_no_extra_I2C_NACK_rollback_manual_unity");
  else $display("TEST_RESULT FAIL digital gain errors=%0d clean=%0d seen=%0d txns=%0d sensor_errors=%0d",errors,clean,seen,transactions,dut.sensor_errors);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
