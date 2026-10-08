`timescale 1ns/1ps
module tb_v26_config;
 reg clk=0,rst=0,sof=0,valid=0,next=0,prev=0;
 always #5 clk=~clk;
 reg [15:0] req=0,cfg=0;reg [7:0] op=0,addr=0;reg [31:0] value=0;
 wire [7:0] mode;wire [15:0] active_id;wire [10:0] gr;wire [7:0] status;
 integer errors=0;
 cvp_cfg_ctrl dut(.clk(clk),.rst_n(rst),.i_sof(sof),.i_next(next),.i_prev(prev),
 .i_valid(valid),.i_req_id(req),.i_cfg_id(cfg),.i_op(op),.i_addr(addr),.i_value(value),
 .i_legacy_valid(1'b0),.i_legacy_cmd(8'd0),.i_legacy_value(24'd0),.i_ticks(64'd0),
 .o_mode(mode),.o_cfg_id(active_id),.o_gain_r(gr),.o_reply_status(status));
 task send;input [7:0] opcode,address;input [31:0] data;input [15:0] configuration;
 begin
  @(negedge clk);valid=1;req=req+1;op=opcode;addr=address;value=data;cfg=configuration;
  @(negedge clk);valid=0;
 end endtask
 initial begin
  #31;rst=1;
  send(1,0,4,1);send(1,6,900,1);
  if(mode!=0||gr!=344)errors=errors+1;
  send(2,0,0,1);if(status!=1)errors=errors+1;
  send(1,0,6,2);if(status!=3)errors=errors+1;
  if(mode!=0)errors=errors+1;
  @(negedge clk);sof=1;#1;if(mode!=4||gr!=900||active_id!=1)errors=errors+1;
  @(negedge clk);sof=0;if(mode!=4||status!=2)errors=errors+1;
  send(2,0,0,1);if(status!=2)errors=errors+1;
  send(1,3,1801,2);if(status!=4)errors=errors+1;
  send(2,0,0,2);if(status!=4||active_id!=1)errors=errors+1;
  @(negedge clk);next=1;@(negedge clk);next=0;
  if(mode!=4)errors=errors+1;
  @(negedge clk);sof=1;@(negedge clk);sof=0;
  if(mode!=5||active_id!=2)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS config_atomic_and_idempotent");
  else $display("TEST_RESULT FAIL config errors%0d",errors);
  $finish;
 end
endmodule
