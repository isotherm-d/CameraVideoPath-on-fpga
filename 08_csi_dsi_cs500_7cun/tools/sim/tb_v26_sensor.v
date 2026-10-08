`timescale 1ns/1ps
module tb_v26_sensor;
 reg clk=0,cc=0,rst=0,valid=0,cam=0,ae_done=1;reg [15:0] exp=0;reg [7:0] gain=0;
 always #5 clk=~clk;always #21 cc=~cc;
 wire req,busy,done,error;wire [15:0] ce,cg,actual_exp;wire [7:0] actual_gain;
 cvp_sensor_bridge dut(.clk(clk),.rst_n(rst),.i_valid(valid),.i_exp(exp),.i_gain(gain),
 .o_busy(busy),.o_exp(actual_exp),.o_gain(actual_gain),.o_done(done),.o_error(error),
 .cfg_clk(cc),.cfg_rst_n(rst),.i_cfg_done(cam),.i_ae_done(ae_done),.i_iic_error(1'b0),
 .o_req(req),.o_cfg_exp(ce),.o_cfg_gain(cg));
 integer transaction=0,count=0,errors=0;reg [15:0] held_exp;reg [15:0] held_gain;
 always @(posedge cc)if(rst)begin
  if(req)begin transaction=transaction+1;ae_done<=0;count=20;held_exp=ce;held_gain=cg;end
  if(count>0)begin
   if(ce!=held_exp||cg!=held_gain)errors=errors+1;
   count=count-1;if(count==0)ae_done<=1;
  end
  if(req&&!cam)errors=errors+1;
 end
 initial begin
  #31;rst=1;repeat(20)@(posedge clk);if(req)errors=errors+1;cam=1;
  wait(req);@(negedge clk);valid=1;exp=700;gain=80;
  @(negedge clk);valid=0;
  @(negedge clk);valid=1;exp=850;gain=88;
  @(negedge clk);valid=0;
  wait(!busy);repeat(5)@(posedge clk);
  if(errors==0&&transaction==2&&actual_exp==850&&actual_gain==88&&!error)$display("TEST_RESULT PASS sensor_cdc_and_busy_queue");
  else $display("TEST_RESULT FAIL sensor errors%0d count%0d exp%0d",errors,transaction,actual_exp);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
