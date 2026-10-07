`timescale 1ns/1ps
module tb_window_coordinates;
localparam W=16,H=8;
reg clk=0,rst=0,valid=0,fs=0;
always #5 clk=~clk;
reg [9:0] raw=0;
wire ov,of,cx,cy;
wire [9:0] p00,p01,p02,p10,p11,p12,p20,p21,p22;
integer frame,x,y,slot=0,seen=-1,checked=0,errors=0,sx,sy,dx,dy;
reg [9:0] actual[0:8];
integer ex,ey,expected;
imgproc_win3x3 #(.IMG_W(W),.IMG_H(H),.DW(10)) dut(
 .i_clk(clk),.i_rst_n(rst),.i_valid(valid),.i_data(raw),.i_frame_start(fs),
 .o_valid(ov),.o_frame_start(of),.o_center_x_odd(cx),.o_center_y_odd(cy),
 .o_p00(p00),.o_p01(p01),.o_p02(p02),.o_p10(p10),.o_p11(p11),.o_p12(p12),
 .o_p20(p20),.o_p21(p21),.o_p22(p22));
always @(negedge clk)if(ov)begin
 if(of)begin seen=seen+1;slot=0;end
 if(seen>=0)begin
  sx=slot%W;sy=slot/W;
  actual[0]=p00;actual[1]=p01;actual[2]=p02;
  actual[3]=p10;actual[4]=p11;actual[5]=p12;
  actual[6]=p20;actual[7]=p21;actual[8]=p22;
  for(dy=0;dy<3;dy=dy+1)for(dx=0;dx<3;dx=dx+1)begin
   ex=sx-2+dx;if(ex<0)ex=0;
   ey=sy-2+dy;if(ey<0)ey=0;
   expected=seen*512+ey*W+ex;
   if(actual[dy*3+dx]!==expected)begin
    if(errors<5)$display("FAIL: slot=%0d neighbour=%0d,%0d got=%0d expected=%0d",slot,dx,dy,actual[dy*3+dx],expected);
    errors=errors+1;
   end
  end
  ex=sx>0?sx-1:0;ey=sy>0?sy-1:0;
  if(cx!==ex[0] || cy!==ey[0])errors=errors+1;
  slot=slot+1;checked=checked+1;
 end
end
initial begin
 #20;rst=1;
 repeat(5)begin @(negedge clk);valid=1;raw=10'd777;@(negedge clk);valid=0;end
 for(frame=0;frame<2;frame=frame+1)begin
  for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
   @(negedge clk);valid=1;fs=(x==0&&y==0);raw=frame*512+y*W+x;
   if(x%3==1)begin @(negedge clk);valid=0;fs=0;repeat(2)@(negedge clk);end
  end
  @(negedge clk);valid=0;fs=0;repeat(4)@(negedge clk);
 end
 repeat(6)@(negedge clk);
 if(errors==0 && checked==256 && seen==1)$display("TEST_RESULT PASS all_window_neighbours_and_parity");
 else $display("TEST_RESULT FAIL window_coordinates errors=%0d checked=%0d frames=%0d",errors,checked,seen+1);
 $finish;
end
endmodule
