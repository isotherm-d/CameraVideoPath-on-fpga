`timescale 1ns/1ps
module tb_v26_bayer;
 localparam W=16,H=8;
 reg clk=0,rst_n=0,v=0,sof=0;reg [9:0] raw;
 always #5 clk=~clk;
 wire valid,fs;wire [23:0] rgb;
 cvp_demosaic #(.IMG_W(W),.IMG_H(H)) dut(.i_clk(clk),.i_rst_n(rst_n),.i_valid(v),
 .i_raw(raw),.i_frame_start(sof),.o_valid(valid),.o_rgb(rgb),.o_frame_start(fs));
 integer err=0,fr,x,y,n=0,seen=-1,total=0;
 always @(negedge clk)if(valid)begin
  if(fs)begin seen=seen+1;n=0;end
  if(rgb!==24'he17d19)begin if(err<4)$display("BAYER FAIL at %0d %0d %h",n%W,n/W,rgb);err=err+1;end
  n=n+1;total=total+1;
 end
 initial begin
  #31;rst_n=1;
  for(fr=0;fr<2;fr=fr+1)begin
   for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
    @(posedge clk);#1;v=1;sof=x==0&&y==0;
    raw=(!y[0]&&!x[0])?100:(y[0]&&x[0])?900:500;
    if(x%4==3)begin @(posedge clk);#1;v=0;sof=0;end
   end
   @(posedge clk);#1;v=0;sof=0;repeat(4)@(posedge clk);
  end
  repeat(100)@(posedge clk);
  if(err==0&&total==W*H*2)$display("TEST_RESULT PASS bayer_all_four_borders");
  else $display("TEST_RESULT FAIL bayer %0d total %0d",err,total);
  $finish;
 end
 initial begin #100000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
