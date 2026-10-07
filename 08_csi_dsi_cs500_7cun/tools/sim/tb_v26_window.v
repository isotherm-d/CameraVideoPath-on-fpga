`timescale 1ns/1ps
module tb_v26_window;
 localparam W=16,H=8;
 reg clk=0,rst_n=0,v=0,sof=0;reg [23:0] pixel;
 always #5 clk=~clk;
 wire valid,fs,eol,eof,overflow;wire [11:0] ox,oy;
 wire [23:0] a,b,c,d,e,f,g,h,i;
 cvp_window3x3 #(.W(W),.H(H),.DW(24),.FIFO_AW(6)) dut(
 .clk(clk),.rst_n(rst_n),.i_valid(v),.i_data(pixel),.i_sof(sof),
 .o_valid(valid),.o_sof(fs),.o_eol(eol),.o_eof(eof),.o_x(ox),.o_y(oy),
 .p00(a),.p01(b),.p02(c),.p10(d),.p11(e),.p12(f),.p20(g),.p21(h),.p22(i),.o_overflow(overflow));
 integer errors=0,seen=-1,count=0,total=0,fr,x,y,j,xx,yy;reg [23:0] neighbours[0:8];
 function [23:0] src;input integer x,y,fr;begin src=fr*10000+y*W+x;end endfunction
 always @(negedge clk)begin
  if(overflow)errors=errors+1;
  if(valid)begin
   if(fs)begin if(seen>=0&&count!=W*H)errors=errors+1;seen=seen+1;count=0;end
   if(ox!=count%W||oy!=count/W||eol!=(ox==W-1)||eof!=(count==W*H-1))errors=errors+1;
   neighbours[0]=a;neighbours[1]=b;neighbours[2]=c;neighbours[3]=d;neighbours[4]=e;
   neighbours[5]=f;neighbours[6]=g;neighbours[7]=h;neighbours[8]=i;
   for(j=0;j<9;j=j+1)begin
    xx=ox+j%3-1;yy=oy+j/3-1;
    if(xx<0)xx=0;if(xx>=W)xx=W-1;if(yy<0)yy=0;if(yy>=H)yy=H-1;
    if(neighbours[j]!==src(xx,yy,seen))begin
     if(errors<6)$display("FAIL xy %0d,%0d n%0d got %h expected %h",ox,oy,j,neighbours[j],src(xx,yy,seen));
     errors=errors+1;
    end
   end
   count=count+1;total=total+1;
  end
 end
 initial begin
  #31;rst_n=1;
  for(fr=0;fr<3;fr=fr+1)begin
   for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
    @(posedge clk);#1;v=1;sof=x==0&&y==0;pixel=src(x,y,fr);
    if((x+y)%4==0)begin @(posedge clk);#1;v=0;sof=0;end
   end
   @(posedge clk);#1;v=0;sof=0;repeat(5)@(posedge clk);
  end
  repeat(100)@(posedge clk);
  if(errors==0&&total==3*W*H)$display("TEST_RESULT PASS centred_rgb_window");else $display("TEST_RESULT FAIL window %0d total %0d",errors,total);
  $finish;
 end
 initial begin #100000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
