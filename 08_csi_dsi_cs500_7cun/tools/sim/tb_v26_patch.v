`timescale 1ns/1ps
module tb_v26_patch;
 reg clk=0,rst=0,valid=0,sop=0,eop=0,ready=0;reg [7:0] data;reg [31:0] fid;
 always #5 clk=~clk;
 wire input_ready,v,os,oe;wire [7:0] out;wire [31:0] frame,dropped;wire [15:0] roi,cfg;wire [63:0] bbox;wire fault;
 cvp_patch_bridge #(.BYTES(16),.ADDR_W(4)) dut(.clk(clk),.rst_n(rst),.i_valid(valid),.i_sop(sop),.i_eop(eop),.i_data(data),
 .i_frame_id(fid),.i_roi_id(16'd5),.i_cfg_id(16'd7),.i_bbox(64'h0001000200030004),.i_ready(input_ready),
 .o_valid(v),.o_sop(os),.o_eop(oe),.o_data(out),.o_frame_id(frame),.o_roi_id(roi),.o_cfg_id(cfg),.o_bbox(bbox),.o_ready(ready),
 .dropped(dropped),.protocol_error(fault));
 integer cycles=0,received=0,errors=0,f,p;
 always @(negedge clk)begin cycles=cycles+1;ready=cycles%3!=0;end
 always @(posedge clk)if(rst&&v&&ready)begin
  if(out!==received%16+received/16*16||frame!==received/16||roi!=5||cfg!=7||
     os!==(received%16==0)||oe!==(received%16==15)||bbox!==64'h0001000200030004)errors=errors+1;
  received=received+1;
 end
 initial begin
  #31;rst=1;
  for(f=0;f<5;f=f+1)for(p=0;p<16;p=p+1)begin
   @(negedge clk);valid=0;
   while(!input_ready)@(negedge clk);
   valid=1;sop=p==0;eop=p==15;data=f*16+p;fid=f;
  end
  @(negedge clk);valid=0;
  repeat(150)@(posedge clk);
  if(errors==0&&received==80&&dropped==0)$display("TEST_RESULT PASS patch_double_bank_and_backpressure");
  else $display("TEST_RESULT FAIL patch errors%0d received%0d dropped%0d",errors,received,dropped);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
