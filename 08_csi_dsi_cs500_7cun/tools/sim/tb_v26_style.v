`timescale 1ns/1ps
module tb_v26_style;
 localparam W=16,H=8,FRAMES=7,N=W*H*FRAMES;
 reg clk=0,rst_n=0,valid=0,sof=0;reg [23:0] rgb;reg [7:0] mode;reg [31:0] frame_id;
 always #5 clk=~clk;
 wire v,fs,eol,eof,overflow;wire [23:0] out;wire [11:0] x,y;wire [31:0] fid;wire [15:0] cid;wire [7:0] om;
 cvp_style #(.W(W),.H(H)) dut(.clk(clk),.rst_n(rst_n),.i_valid(valid),.i_rgb(rgb),.i_sof(sof),
 .i_frame_id(frame_id),.i_cfg_id(16'd17),.i_mode(mode),.i_binary_th(8'd130),.i_edge_low(11'd130),.i_edge_high(11'd190),
 .o_valid(v),.o_rgb(out),.o_sof(fs),.o_eol(eol),.o_eof(eof),.o_x(x),.o_y(y),
 .o_frame_id(fid),.o_cfg_id(cid),.o_mode(om),.o_overflow(overflow));
 reg [23:0] input_image[0:N-1],expected[0:N-1];
 integer n,f,p,received=0,errors=0;
 always @(negedge clk)begin
  if(overflow)errors=errors+1;
  if(v)begin
   if(out!==expected[received]||fid!==received/(W*H)||om!==received/(W*H)||cid!==17||
      x!==received%W||y!==(received%(W*H))/W||fs!==(received%(W*H)==0)||eol!==(received%W==W-1)||eof!==(received%(W*H)==W*H-1))begin
    if(errors<8)$display("STYLE FAIL at %0d mode%0d xy%0d,%0d actual %h expected %h",received,om,x,y,out,expected[received]);
    errors=errors+1;
   end
   received=received+1;
  end
 end
 initial begin
  $readmemh("style_input.mem",input_image);$readmemh("style_expected.mem",expected);
  #31;rst_n=1;
  for(f=0;f<FRAMES;f=f+1)begin
   for(p=0;p<W*H;p=p+1)begin
    @(posedge clk);#1;valid=1;sof=p==0;rgb=input_image[f*W*H+p];mode=f;frame_id=f;
    if(p%4==3)begin @(posedge clk);#1;valid=0;sof=0;end
   end
   @(posedge clk);#1;valid=0;sof=0;repeat(40)@(posedge clk);
  end
  repeat(100)@(posedge clk);
  if(errors==0&&received==N)$display("TEST_RESULT PASS seven_styles_all_pixels_and_metadata");
  else $display("TEST_RESULT FAIL styles errors%0d received%0d",errors,received);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL timeout");$finish;end
endmodule
