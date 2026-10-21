`timescale 1ns/1ps
module tb_five_sampler;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,en=1,v=0;reg [11:0] x=0,y=0;reg [31:0] frame=1;reg [15:0] cfg=7;
 wire b2,b3,a2,a3;
 yolo160_first #(.FRAME_INTERVAL(2),.FULL_FRAME(1),.WFILE("first8.hex")) d2(.clk(clk),.rst_n(rst),.i_enable(en),.i_valid(v),.i_x(x),.i_y(y),.i_rgb(24'h010203),.i_frame(frame),.i_cfg(cfg),.busy(b2),.done(),.aborted(a2),.we(),.addr(),.data(),.frame_id(),.cfg_id());
 yolo160_first #(.FRAME_INTERVAL(3),.FULL_FRAME(1),.WFILE("first8.hex")) d3(.clk(clk),.rst_n(rst),.i_enable(en),.i_valid(v),.i_x(x),.i_y(y),.i_rgb(24'h010203),.i_frame(frame),.i_cfg(cfg),.busy(b3),.done(),.aborted(a3),.we(),.addr(),.data(),.frame_id(),.cfg_id());
 task pixel(input integer xx,yy);
  begin @(negedge clk);v=1;x=xx;y=yy;@(negedge clk);v=0;end
 endtask
 task reset;
  begin @(negedge clk);rst=0;v=0;cfg=7;en=1;repeat(3)@(negedge clk);rst=1;end
 endtask
 initial begin
  reset();
  for(integer f=0;f<9;f=f+1)begin
   frame=f+1;pixel(4,2);
   if(b2!==1'(f%2==0)||b3!==1'(f%3==0))$fatal(1,"fullframe cadence");
   pixel(20,2);if(b2||b3||a2!==1'(f%2==0)||a3!==1'(f%3==0))$fatal(1,"fullframe skipped pixel");
  end
  reset();pixel(4,2);@(negedge clk);cfg=8;@(negedge clk);if(b2||b3||!a2||!a3)$fatal(1,"cfg abort");
  reset();pixel(4,2);@(negedge clk);frame=frame+1;@(negedge clk);if(b2||b3||!a2||!a3)$fatal(1,"partial frame abort");
  reset();pixel(4,2);pixel(12,3);if(b2||b3||!a2||!a3)$fatal(1,"sampled row ended early");
  reset();en=0;pixel(4,2);if(b2||b3)$fatal(1,"backpressure capture");
  $display("TEST_RESULT PASS tb_five_sampler fullframe 10/15Hz sample loss row loss cfg frame backpressure");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
