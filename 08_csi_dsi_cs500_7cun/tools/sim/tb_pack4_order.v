`timescale 1ns/1ps
module tb_pack4_order;
reg clk=0,rst=0,valid=0,fs=0;
always #5 clk=~clk;
reg [23:0] rgb=0;
wire out_valid,out_fs;
wire [95:0] data;
integer frame,p,groups=0,errors=0;
reg [95:0] expected;
pack_4 dut(.I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_rgb(rgb),.I_frame_start(fs),.O_tvalid(out_valid),.O_tdata(data),.O_tuser(out_fs));
function [23:0] pixel(input integer index);
reg [7:0] r,g,b;
begin r=index*17;g=index*37;b=index*51;pixel={r,g,b};end
endfunction
always @(negedge clk)if(out_valid)begin
 expected={pixel(groups*4),pixel(groups*4+1),pixel(groups*4+2),pixel(groups*4+3)};
 if(data!==expected || out_fs!==(groups%2==0))begin
  $display("FAIL: group=%0d data=%h expected=%h",groups,data,expected);errors=errors+1;
 end
 groups=groups+1;
end
initial begin
 #20;rst=1;
 // Discard a partial group when the actual frame begins.
 repeat(2)begin @(negedge clk);valid=1;rgb=24'habcdef;end
 for(frame=0;frame<2;frame=frame+1)begin
  for(p=0;p<8;p=p+1)begin
   @(negedge clk);valid=1;fs=(p==0);rgb=pixel(frame*8+p);
   @(negedge clk);valid=0;fs=0;
   repeat(p%3)@(negedge clk);
  end
 end
 repeat(4)@(negedge clk);
 if(errors==0 && groups==4)$display("TEST_RESULT PASS pixel_group_chronological_order");
 else $display("TEST_RESULT FAIL pack4 errors=%0d groups=%0d",errors,groups);
 $finish;
end
endmodule
