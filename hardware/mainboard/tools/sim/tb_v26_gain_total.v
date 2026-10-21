`timescale 1ns/1ps
module tb_v26_gain_total;
reg clk=0,rst=0,v=0,sof=0,swap=0;always #5 clk=~clk;
reg [23:0] rgb=0;reg [10:0] r=344,g=256,b=451,dg=256;
wire [21:0] pr=r*dg+128,pg=g*dg+128,pb=b*dg+128;
wire nv,ns,ov,os;wire [23:0] nrgb,orgb;
cvp_gain11 dut(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_rgb(rgb),
 .i_r(pr[20:8]),.i_g(pg[20:8]),.i_b(pb[20:8]),.i_swap(swap),.o_valid(nv),.o_sof(ns),.o_rgb(nrgb));
cvp_gain11_v33_gold reference(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_rgb(rgb),
 .i_r(r),.i_g(g),.i_b(b),.i_swap(swap),.o_valid(ov),.o_sof(os),.o_rgb(orgb));
integer n,errors=0,checked=0,unity=0,seed=34;
reg [31:0] bits;
function [7:0] pixel;input [7:0] p;input [10:0] wb,digital;integer coefficient,z;begin
 coefficient=(wb*digital+128)/256;z=(p*coefficient+128)/256;pixel=z>255?255:z;
end endfunction
always @(posedge clk)begin
 #1;
 if(rst)begin
  checked=checked+1;
  if(nv!==v||ns!==(v&&sof)||nrgb!=={pixel(swap?rgb[7:0]:rgb[23:16],r,dg),pixel(rgb[15:8],g,dg),pixel(swap?rgb[23:16]:rgb[7:0],b,dg)})errors=errors+1;
  if(dg==256)begin unity=unity+1;if({nv,ns,nrgb}!=={ov,os,orgb})errors=errors+1;end
 end
end
initial begin
 repeat(4)@(negedge clk);rst=1;
 for(n=0;n<100000;n=n+1)begin
  @(negedge clk);bits=$random(seed);rgb=$random(seed);v=bits[0];sof=bits[1];swap=bits[2];
  r=64+(bits[15:3]%961);g=64+(bits[28:16]%961);b=64+(bits[31:19]%961);
  dg=n%4==0?256:256+(bits%769);
  if(n%5000==0)begin r=1024;g=1024;b=1024;dg=1024;rgb=24'hff1001;end
  if(n==50000)begin rst=0;repeat(4)@(negedge clk);rst=1;end
 end
 @(negedge clk);
 if(errors==0&&checked>=100000&&unity>=24000)$display("TEST_RESULT PASS combined_WB_digital_gain_rounding_saturation_unity_equivalence checked=%0d unity=%0d",checked,unity);
 else $display("TEST_RESULT FAIL gain total errors=%0d checked=%0d unity=%0d",errors,checked,unity);
 $finish;
end
endmodule
