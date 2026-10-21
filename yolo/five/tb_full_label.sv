`timescale 1ns/1ps
module tb_full_label;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,v=0,sof=0;reg [11:0] x=0,y=0;reg [31:0] frame=0;
 reg [47:0] box={12'd100,12'd100,12'd300,12'd300};reg [2:0] cls=0;reg known=1;
 wire ov,os;wire [23:0] rgb;wire [31:0] oframe;
 cvp_cell_label #(.N(1),.FULL_NAMES(1)) dut(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_rgb(24'h555555),.i_x(x),.i_y(y),.i_frame(frame),
 .i_sw1_n(1'b1),.i_boxes(box),.i_classes(cls),.i_known(known),.o_valid(ov),.o_sof(os),.o_rgb(rgb),.o_frame(oframe));
 // Independent literal names and 5x7 reference raster, including the final
 // characters past the former 48-pixel abbreviation panel.
 function [79:0] name(input integer c);
  case(c)0:name="Basophil  ";1:name="Eosinophil";2:name="Lymphocyte";3:name="Monocyte  ";4:name="Neutrophil";default:name="WAIT      ";endcase
 endfunction
 function [34:0] font(input [7:0] c);
  case(c)
   "B":font=35'b11110_10001_10001_11110_10001_10001_11110;
   "E":font=35'b11111_10000_10000_11110_10000_10000_11111;
   "L":font=35'b10000_10000_10000_10000_10000_10000_11111;
   "M":font=35'b10001_11011_10101_10101_10001_10001_10001;
   "N":font=35'b10001_11001_10101_10011_10001_10001_10001;
   "W":font=35'b10001_10001_10001_10101_10101_11011_10001;
   "A":font=35'b01110_10001_10001_11111_10001_10001_10001;
   "I":font=35'b01110_00100_00100_00100_00100_00100_01110;
   "T":font=35'b11111_00100_00100_00100_00100_00100_00100;
   "a":font=35'b00000_00000_01110_00001_01111_10001_01111;
   "c":font=35'b00000_00000_01111_10000_10000_10000_01111;
   "e":font=35'b00000_00000_01110_10001_11111_10000_01111;
   "h":font=35'b10000_10000_10110_11001_10001_10001_10001;
   "i":font=35'b00100_00000_01100_00100_00100_00100_01110;
   "l":font=35'b01100_00100_00100_00100_00100_00100_01110;
   "m":font=35'b00000_00000_11010_10101_10101_10101_10101;
   "n":font=35'b00000_00000_10110_11001_10001_10001_10001;
   "o":font=35'b00000_00000_01110_10001_10001_10001_01110;
   "p":font=35'b00000_11110_10001_10001_11110_10000_10000;
   "r":font=35'b00000_00000_10110_11001_10000_10000_10000;
   "s":font=35'b00000_00000_01111_10000_01110_00001_11110;
   "t":font=35'b00100_00100_11111_00100_00100_00100_00011;
   "u":font=35'b00000_00000_10001_10001_10001_10011_01101;
   "y":font=35'b00000_00000_10001_10001_01111_00001_01110;
   default:font=0;
  endcase
 endfunction
 reg [2:0] qv=0,qs=0;reg [31:0] qf[0:2];reg [23:0] expected[0:2];
 reg [23:0] want;reg [79:0] word;reg [34:0] bits;
 integer px,py,bx0,by0,bx1,by1,dx,dy,col,row;integer checked=0;reg ink;
 always_comb begin
  bx0=box[47:36]>16?box[47:36]-16:0;by0=box[35:24]>16?box[35:24]-16:0;
  bx1=box[23:12]>=1264?1279:box[23:12]+16;by1=box[11:0]>=704?719:box[11:0]+16;
  px=by0>=16?bx0:bx0+2;if(px>1120)px=1120;
  py=by0>=16?by0-16:by0+2;if(py>704)py=704;
  word=name(known?cls:5);dx=x-px;dy=y-py;col=dx/16;row=dy/2;
  bits=(col>=0&&col<10)?font(word[79-col*8-:8]):35'd0;
  ink=dx>=0&&dy>=0&&col<10&&row<7&&((dx%16)/2)<5&&bits[34-row*5-(dx%16)/2];
  want=24'h555555;
  if(x>=bx0&&x<=bx1&&y>=by0&&y<=by1&&(x-bx0<2||bx1-x<2||y-by0<2||by1-y<2))want=24'h00ff00;
  if(x>=px&&x<px+160&&y>=py&&y<py+16)want=ink?(known?24'h00ffff:24'hffff00):24'h000000;
 end
 always @(posedge clk)if(rst)begin
  if(ov!==qv[2])$fatal(1,"full name valid latency");
  if(ov)begin
   if(rgb!==expected[2]||oframe!==qf[2]||os!==qs[2])$fatal(1,"full name pixel/metadata mismatch frame %0d got=%h expected=%h",oframe,rgb,expected[2]);
   checked=checked+1;
  end
  qv<={qv[1:0],v};qs<={qs[1:0],sof};expected[0]<=want;qf[0]<=frame;
  for(integer z=1;z<3;z=z+1)begin expected[z]<=expected[z-1];qf[z]<=qf[z-1];end
 end
 task pixel(input integer xx,yy);
  begin @(negedge clk);v=1;sof=0;x=xx;y=yy;end
 endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(integer c=0;c<7;c=c+1)begin
   @(negedge clk);v=0;cls=3'(c<5?c:4);known=c!=6;frame=c+1;
   box=c==5?{12'd1250,12'd0,12'd1279,12'd80}:{12'd100,12'd100,12'd300,12'd300};
   @(negedge clk);v=1;sof=1;x=0;y=0;
   @(negedge clk);v=0;sof=0;
   repeat(5)@(negedge clk);
   for(integer yy=0;yy<16;yy=yy+1)for(integer xx=0;xx<160;xx=xx+1)pixel((c==5?1120:84)+xx,(c==5?2:68)+yy);
   pixel(c==5?1234:84,c==5?40:120);pixel(20,400);
   @(negedge clk);v=0;repeat(6)@(negedge clk);
  end
  if(checked<17920)$fatal(1,"incomplete name raster");
  $display("TEST_RESULT PASS tb_full_label five complete English names 160x16 raster right/top clipping WAIT green border RGB metadata checked=%0d",checked);$finish;
 end
 initial begin #250000;$fatal(1,"timeout");end
endmodule
