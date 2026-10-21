`timescale 1ns/1ps
module tb_v26_commands;
 reg rc=0,cc=0,rst=0,ctl=0;reg [3:0] d=0;
 always #4 rc=~rc;always #5 cc=~cc;
 wire v;wire [15:0] req,cfg;wire [7:0] op,addr;wire [31:0] value;
 integer events=0,errors=0,k,length;
 reg [7:0] packet[0:83];
 cvp_cmd_rx dut(.I_rxclk(rc),.I_rst_n_rx(rst),.I_rxd(d),.I_rxctl(ctl),.I_rst_n_gmii(rst),.I_clk_gmii(rc),
 .I_clk100(cc),.I_rst_n_100(rst),.o_v2_valid(v),.o_req_id(req),.o_cfg_id(cfg),.o_op(op),.o_addr(addr),.o_value(value));
 always @(posedge cc)if(v)events=events+1;
 task byte;input [7:0] data;begin
  @(negedge rc);#1;ctl=1;d=data[3:0];@(posedge rc);#1;d=data[7:4];
 end endtask
 task send;input integer malformed;begin
  for(k=0;k<84;k=k+1)packet[k]=0;
  for(k=0;k<7;k=k+1)packet[k]=8'h55;
  packet[7]=8'hd5;packet[20]=8'h08;packet[31]=8'h11;packet[44]=8'h17;packet[45]=8'h71;
  packet[50]=8'hc5;packet[51]=8'ha5;packet[52]=8'h50;packet[53]=8'h02;
  packet[54]=8'hab;packet[55]=8'hcd;packet[56]=8'h12;packet[57]=8'h34;
  packet[58]=1;packet[59]=6;packet[62]=8'h98;packet[63]=8'h76;packet[64]=8'h54;packet[65]=8'h32;
  if(malformed==1)packet[53]=8'h03;
  length=malformed==2?65:84;
  for(k=0;k<length;k=k+1)byte(packet[k]);
  @(negedge rc);#1;ctl=0;repeat(30)@(negedge rc);
 end endtask
 initial begin
  #100;rst=1;send(0);
  if(events!=1||req!=16'habcd||cfg!=16'h1234||op!=1||addr!=6||value!=32'h98765432)errors=errors+1;
  send(1);send(2);if(events!=1)errors=errors+1;
  send(0);if(events!=2)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS v2_full_width_and_malformed_rx");
  else $display("TEST_RESULT FAIL commands %0d events%0d value%h",errors,events,value);
  $finish;
 end
endmodule
