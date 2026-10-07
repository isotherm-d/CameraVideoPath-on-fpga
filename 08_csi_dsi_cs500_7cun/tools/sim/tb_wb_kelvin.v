`timescale 1ns/1ps
module tb_wb_kelvin;
reg clk=0,rst=0,en=0,preset=1,swap=0;
always #5 clk=~clk;
reg [6:0] kelvin=65;
reg [8:0] mr=300,mg=280,mb=240;
wire valid,selected_swap;
wire [8:0] red,blue,sr,sg,sb;
integer errors=0,k,last_r,last_b;
// Reference-scene fixture; update these only after recording the calibration.
localparam [8:0] CAL_R=291, CAL_B=246;
wb_kelvin dut(.I_clk(clk),.I_rst_n(rst),.I_en(en),.I_kelvin_hk(kelvin),.o_valid(valid),.o_gain_r(red),.o_gain_b(blue));
cvp_wb_select selector(.I_clk(clk),.I_rst_n(rst),.I_preset(preset),.I_kelvin(kelvin),.I_r(mr),.I_g(mg),.I_b(mb),.I_swap(swap),.O_r(sr),.O_g(sg),.O_b(sb),.O_swap(selected_swap));
task check(input condition,input [8*80-1:0] label);
begin if(condition!==1'b1)begin $display("FAIL: %0s",label);errors=errors+1;end end
endtask
task sample(input [6:0] value);
begin
 @(negedge clk);kelvin=value;en=1;
 @(posedge clk);@(posedge clk);#1;
 check(valid===1'b1,"two-stage temperature valid");
end
endtask
initial begin
 #20;rst=1;
 sample(65);check(red===CAL_R && blue===CAL_B,"reference uses sensor calibration");
 last_r=0;last_b=511;
 for(k=25;k<=100;k=k+1)begin
  sample(k);
  check(red>=last_r && blue<=last_b && red>=64 && blue>=64,"smooth monotonic bounded temperature curve");
  last_r=red;last_b=blue;
 end
 sample(25);last_r=red;last_b=blue;
 sample(0);check(red==last_r && blue==last_b,"lower temperature clamp");
 sample(100);last_r=red;last_b=blue;
 sample(127);check(red==last_r && blue==last_b,"upper temperature clamp");
 preset=1;sample(25);check(sr===CAL_R && sg===256 && sb===CAL_B,"preset ignores temperature slider");
 swap=1;#1;check(selected_swap===1'b1,"swap enabled in preset");
 preset=0;sample(65);check(sr===CAL_R && sg===256 && sb===CAL_B,"Kelvin uses same reference as preset");
 sample(0);check(sr===mr && sg===mg && sb===mb,"manual RGB overrides stale temperature");
 mr=511;mg=64;mb=256;#1;check(sr===511 && sg===64 && sb===256,"all three manual gains reach output");
 swap=0;#1;check(selected_swap===1'b0,"swap can be disabled in manual");
 @(negedge clk);en=0;@(posedge clk);@(posedge clk);#1;
 check(valid===1'b0,"temperature disabled valid");
 if(errors==0)$display("TEST_RESULT PASS temperature_and_mode_selection");
 else $display("TEST_RESULT FAIL wb_kelvin errors=%0d",errors);
 $finish;
end
endmodule
