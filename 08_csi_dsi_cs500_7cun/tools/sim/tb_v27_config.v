`timescale 1ns/1ps
module tb_v27_config;
 reg clk=0,rst=0,sof=0,v=0;reg [15:0] rid=0,cid=0;reg [7:0] op,addr;reg [31:0] value;
 always #5 clk=~clk;
 wire [10:0] el,eh,sl,sh;wire [1:0] ew,sw;wire [7:0] reply;wire [31:0] readback;integer errors=0;
 cvp_cfg_ctrl dut(.clk(clk),.rst_n(rst),.i_sof(sof),.i_next(1'b0),.i_prev(1'b0),.i_valid(v),.i_req_id(rid),.i_cfg_id(cid),
 .i_op(op),.i_addr(addr),.i_value(value),.i_legacy_valid(1'b0),.i_legacy_cmd(8'd0),.i_legacy_value(24'd0),.i_ticks(64'd0),
 .o_edge_low(el),.o_edge_high(eh),.o_sketch_low(sl),.o_sketch_high(sh),.o_edge_width(ew),.o_sketch_width(sw),.o_reply_status(reply),.o_reply_value(readback));
 task send;input [15:0] cfg;input [7:0] operation,address;input [31:0] data;
 begin @(negedge clk);rid=rid+1;cid=cfg;op=operation;addr=address;value=data;v=1;@(negedge clk);v=0;end endtask
 initial begin
  #31;rst=1;send(1,1,13,40);send(1,1,14,80);send(1,1,15,25);send(1,1,16,50);send(1,1,18,2);send(1,2,0,0);
  if(el!=45||sl!=50)errors=errors+1;
  @(negedge clk);sof=1;@(negedge clk);sof=0;
  if(el!=40||eh!=80||sl!=25||sh!=50||sw!=2||ew!=1)errors=errors+1;
  send(2,1,13,900);send(2,2,0,0);if(reply!=4)errors=errors+1;
  @(negedge clk);sof=1;@(negedge clk);sof=0;if(el!=40||eh!=80)errors=errors+1;
  send(3,1,14,100);send(3,2,0,0);@(negedge clk);sof=1;@(negedge clk);sof=0;
  send(3,3,16,0);if(readback!=50||eh!=100||sl!=25)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS v27_independent_profiles_atomic_rejection_and_readback");
  else $display("TEST_RESULT FAIL config errors%0d",errors);
  $finish;
 end
endmodule
