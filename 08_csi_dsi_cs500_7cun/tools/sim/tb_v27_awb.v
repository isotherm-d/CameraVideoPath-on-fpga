`timescale 1ns/1ps
module tb_v27_awb;
 reg clk=0,rst=0,v=0,sof=0,eof=0,en=1;reg [23:0] raw,rgb;
 always #5 clk=~clk;
 wire done,fault;wire [10:0] r,g,b;wire [1:0] state;wire [7:0] reason;wire [3:0] regions;wire [31:0] neutral;
 cvp_frame_stats #(.W(16),.H(8),.SAFE_AWB(1)) dut(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_eof(eof),.i_rgb(rgb),.i_raw_rgb(raw),.i_awb_en(en),
 .o_done(done),.o_awb_r(r),.o_awb_g(g),.o_awb_b(b),.o_awb_state(state),.o_stat_overrun(fault),.o_neutral(neutral),.o_awb_reason(reason),.o_awb_regions(regions));
 integer p,n,errors=0;reg [10:0] saved_r,saved_b;
 task frame;input [23:0] sample,corrected;input one_region;
 begin
  for(p=0;p<128;p=p+1)begin
   @(negedge clk);v=1;sof=p==0;eof=p==127;
   raw=one_region&&(p%16>=8||p/16>=4)?24'h28140a:sample;rgb=corrected;
  end
  @(negedge clk);v=0;sof=0;eof=0;wait(done);@(negedge clk);
  if(fault)errors=errors+1;
 end endtask
 initial begin
  #31;rst=1;
  frame({8'd90,8'd100,8'd45},24'h79644f,0);
  if(neutral!=0||state!=2||r!=344||b!=451)errors=errors+1;
  for(n=0;n<25;n=n+1)frame({8'd75,8'd105,8'd57},24'h656964,0);
  if(state!=1||regions!=15||r<344||r>354||b<451||b>464)errors=errors+1;
  saved_r=r;saved_b=b;
  frame({8'd75,8'd100,8'd57},24'h656464,1);
  if(state!=2||reason!=3||r!=saved_r||b!=saved_b)errors=errors+1;
  frame(24'hffffff,24'hffffff,0);if(neutral!=0||state!=2)errors=errors+1;
  en=0;frame(0,0,0);if(r!=344||b!=451||state!=0)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS v27_awb_prior_beige_clip_and_region_guards");
  else $display("TEST_RESULT FAIL v27_awb errors%0d r%0d b%0d regions%0d",errors,r,b,regions);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL awb timeout");$finish;end
endmodule
