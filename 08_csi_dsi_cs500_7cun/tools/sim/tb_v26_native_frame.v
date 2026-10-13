`timescale 1ns/1ps
module tb_v26_native_frame;
 reg clk=0,rst=0,v=0,start=0,finish=0;reg [39:0] data=0;always #5 clk=~clk;
 wire av,as,al;wire [39:0] ad;wire ov,os,ol;wire [39:0] od;
 wire gv,gs,gl;wire [39:0] gd;integer errors=0,seen=0,sofs=0,lasts=0,old_sofs=0,n;
 uial2axis #(.IMG_WIDTH(16),.IMG_HEIGHT(4),.INPUT_DATA_WIDTH(40)) dut(
  .I_native_clk(clk),.I_rst_n(rst),.I_data(data),.I_data_valid(v),.I_data_start(start),.I_data_end(finish),
  .axis_tvalid(av),.axis_tdata(ad),.axis_tuser(as),.axis_tlast(al));
 uial2axis_v35_gold #(.IMG_WIDTH(16),.IMG_HEIGHT(4),.INPUT_DATA_WIDTH(40)) gold(
  .I_native_clk(clk),.I_rst_n(rst),.I_data(data),.I_data_valid(v),.I_data_start(start),.I_data_end(finish),
  .axis_tvalid(gv),.axis_tdata(gd),.axis_tuser(gs),.axis_tlast(gl));
 line_retimer #(.BEATS_PER_LINE(4),.LINES(4)) window(
  .I_clk(clk),.I_rst_n(rst),.I_tuser(as),.I_tvalid(av),.I_tdata(ad),.O_tuser(os),.O_tvalid(ov),.O_tlast(ol),.O_tdata(od));
 always @(posedge clk)begin
  if(gv&&gs)old_sofs=old_sofs+1;
  #1;if(ov)begin seen=seen+1;if(os)sofs=sofs+1;if(ol)lasts=lasts+1;end
 end
 task beat;input integer value;input first;begin
  @(negedge clk);v=1;start=first;data=value;@(negedge clk);v=0;start=0;repeat(2)@(negedge clk);
 end endtask
 task blank_start;begin @(negedge clk);start=1;@(negedge clk);start=0;repeat(5)@(negedge clk);end endtask
 initial begin
  #31;rst=1;
  // Native start and first valid coincide. First group must not be skipped.
  for(n=0;n<16;n=n+1)beat(n,n==0);repeat(8)@(negedge clk);
  if(seen!=16||sofs!=1||lasts!=4)errors=errors+1;
  // Excess payload must not create another synthetic frame at count wrap.
  repeat(4)beat(99,0);repeat(8)@(negedge clk);
  if(seen!=16||sofs!=1)errors=errors+1;
  blank_start();for(n=0;n<13;n=n+1)beat(100+n,0);repeat(8)@(negedge clk);
  blank_start();for(n=0;n<16;n=n+1)beat(200+n,0);repeat(8)@(negedge clk);
  if(seen!=45||sofs!=3||lasts!=11||old_sofs<=sofs)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS native_SOF_no_count_wrap_or_first_group_loss seen=%0d new_sofs=%0d old_sofs=%0d",seen,sofs,old_sofs);
  else $display("TEST_RESULT FAIL native frame errors=%0d seen=%0d sofs=%0d lasts=%0d old=%0d",errors,seen,sofs,lasts,old_sofs);
  $finish;
 end
endmodule
