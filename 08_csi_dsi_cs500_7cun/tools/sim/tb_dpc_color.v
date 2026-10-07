`timescale 1ns/1ps
module tb_dpc_color;
reg clk=0,rst=0,valid=0,fs=0;
always #5 clk=~clk;
reg [9:0] raw=0;
wire v0,v1,f0,f1;
wire [9:0] corrected,original,window_original;
integer x,y,changed=0,samples=0,errors=0,cx,cy,expected;
cvp_dpc #(.IMG_W(32),.IMG_H(16),.BYPASS(0)) active(.i_clk(clk),.i_rst_n(rst),.i_valid(valid),.i_raw(raw),.i_frame_start(fs),.o_valid(v0),.o_raw(corrected),.o_frame_start(f0));
cvp_dpc #(.IMG_W(32),.IMG_H(16),.BYPASS(1)) reference(.i_clk(clk),.i_rst_n(rst),.i_valid(valid),.i_raw(raw),.i_frame_start(fs),.o_valid(v1),.o_raw(original),.o_frame_start(f1));
cvp_dpc_legacy #(.IMG_W(32),.IMG_H(16),.BYPASS(1)) old_centre(.i_clk(clk),.i_rst_n(rst),.i_valid(valid),.i_raw(raw),.i_frame_start(fs),.o_valid(),.o_raw(window_original),.o_frame_start());
always @(negedge clk)if(v0 && v1)begin
 samples=samples+1;
 cx=((samples-1)%32);cy=((samples-1)/32);
 expected=((cx%2)==0&&(cy%2)==0)?100:((cx%2)==1&&(cy%2)==1)?900:500;
 if(original!==expected)begin
  if(errors<3)$display("FAIL: delayed RAW sample=%0d expected=%0d result=%0d",samples,expected,original);
  errors=errors+1;
 end
 if(samples>96 && corrected!==window_original)begin
  changed=changed+1;
  if(changed<5)$display("DPC_CHANGED genuine_color_sample=%0d result=%0d",window_original,corrected);
 end
end
initial begin
 #20;rst=1;
 for(y=0;y<16;y=y+1)for(x=0;x<32;x=x+1)begin
  @(negedge clk);valid=1;fs=(x==0&&y==0);
  raw=((x%2)==0&&(y%2)==0)?100:((x%2)==1&&(y%2)==1)?900:500;
 end
 @(negedge clk);valid=0;fs=0;repeat(10)@(negedge clk);
 $display("DPC_COLOR_DIAGNOSTIC changed=%0d samples=%0d",changed,samples);
 if(changed>0 && samples==512 && errors==0) $display("TEST_RESULT PASS dpc_color_preservation");
 else $display("TEST_RESULT FAIL dpc_color_preservation");
 $finish;
end
endmodule
