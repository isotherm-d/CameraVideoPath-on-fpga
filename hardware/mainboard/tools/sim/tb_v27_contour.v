`timescale 1ns/1ps
module tb_v27_contour;
 localparam W=16,H=8,N=896;
 reg clk=0,rst=0,v=0;reg [127:0] pixel;reg [10:0] low,high;
 always #5 clk=~clk;
 wire ov,fault;wire [127:0] out;
 cvp_style_stream #(.W(W),.H(H),.USE_CONTOUR(1)) dut(.clk(clk),.rst_n(rst),.i_valid(v),.i_pixel(pixel),
 .i_binary_th(8'd130),.i_edge_low(low),.i_edge_high(high),.i_edge_width(2'd1),.o_valid(ov),.o_pixel(out),.o_overflow(fault));
 reg [23:0] source[0:N-1],expected[0:N-1];integer f,p,seen=0,errors=0;
 always @(negedge clk)begin
  if(fault)begin errors=errors+1;$display("FAULT at %t",$time);end
  if(ov)begin
   if(out[23:0]!==expected[seen]||out[79:48]!==seen/128||out[95:80]!==16'd17||out[103:96]!==seen/128||
      out[35:24]!==seen%16||out[47:36]!==(seen%128)/16||out[104]!==(seen%128==0)||out[105]!==(seen%16==15)||out[106]!==(seen%128==127))begin
    if(errors<10)$display("V27 mismatch %0d rgb%h expected%h mode%0d xy%0d,%0d fid%0d",seen,out[23:0],expected[seen],out[103:96],out[35:24],out[47:36],out[79:48]);errors=errors+1;
   end
   seen=seen+1;
  end
 end
 initial begin
  $readmemh("style_input.mem",source);$readmemh("v27_style_expected.mem",expected);
  #31;rst=1;
  for(f=0;f<7;f=f+1)begin
   low=f==5?50:65;high=f==5?100:130;
   for(p=0;p<128;p=p+1)begin
    @(posedge clk);#1;v=1;pixel={16'd0,4'b1000,1'b0,p==127,p%16==15,p==0,f[7:0],16'd17,f[31:0],12'd0,12'd0,source[f*128+p]};
    if(p%4==3)begin @(posedge clk);#1;v=0;end
   end
   @(posedge clk);#1;v=0;repeat(160)@(posedge clk);
  end
  repeat(200)@(posedge clk);
  if(errors==0&&seen==N)$display("TEST_RESULT PASS v27_contours_and_all_mode_metadata");
  else $display("TEST_RESULT FAIL contour errors%0d seen%0d",errors,seen);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL contour timeout");$finish;end
endmodule
