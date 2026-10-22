`timescale 1ns/1ps
module tb_v26_keys;
 reg clk=0,rst=0;reg [1:0] keys=3;wire next,prev;
 always #5 clk=~clk;
 cvp_keys #(.DEBOUNCE(4)) dut(.clk(clk),.rst_n(rst),.keys_n(keys),.next(next),.prev(prev));
 integer n=0,p=0,errors=0;
 always @(posedge clk)begin if(next)n=n+1;if(prev)p=p+1;end
 initial begin
  #31;rst=1;repeat(5)@(negedge clk);
  keys[0]=0;@(negedge clk);keys[0]=1;repeat(6)@(negedge clk);
  if(n!=0||p!=0)errors=errors+1;
  keys[0]=0;repeat(14)@(negedge clk);if(p!=1||n!=0)errors=errors+1;
  repeat(14)@(negedge clk);if(p!=1||n!=0)errors=errors+1;
  keys[0]=1;repeat(8)@(negedge clk);
  keys[1]=0;repeat(14)@(negedge clk);if(p!=1||n!=1)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS KEY2_previous_KEY3_next_bounce_and_single_press");
  else $display("TEST_RESULT FAIL keys %0d",errors);
  $finish;
 end
endmodule
