`timescale 1ns/1ps
module tb_color_correct;
reg clk=0,rst_n=0,valid=0,frame_start=0,swap=0;
always #5 clk=~clk;
reg [23:0] rgb=0;
reg [8:0] gain=0;
wire [23:0] result,parameter_swap;
wire result_valid,result_fs;
integer g,p,r,b,effective,expected_r,expected_g,expected_b,errors=0;
color_correct dut(.I_clk(clk),.I_rst_n(rst_n),.I_valid(valid),.I_rgb(rgb),.I_frame_start(frame_start),.I_gain_r_rt(gain),.I_gain_g_rt(gain),.I_gain_b_rt(gain),.I_swap_rt(swap),.O_valid(result_valid),.O_rgb(result),.O_frame_start(result_fs));
color_correct #(.SWAP_RB(1)) fixed_swap(.I_clk(clk),.I_rst_n(rst_n),.I_valid(valid),.I_rgb(rgb),.I_frame_start(frame_start),.I_gain_r_rt(gain),.I_gain_g_rt(gain),.I_gain_b_rt(gain),.I_swap_rt(swap),.O_valid(),.O_rgb(parameter_swap),.O_frame_start());
function integer q8;
 input integer value,multiplier;
 integer scaled;
 begin scaled=(value*multiplier+128)/256;q8=(scaled>255)?255:scaled;end
endfunction
initial begin
 #20;rst_n=1;
 // Exhaust every 8-bit pixel and every 9-bit gain, including fallback gain zero.
 for(g=0;g<512;g=g+1) begin
  for(p=0;p<256;p=p+1) begin
   @(negedge clk);gain=g;rgb={p[7:0],(8'd255-p[7:0]),(p[7:0]*8'd37)};
   swap=p[0];valid=(p%17!=0);frame_start=valid && (p==1);
   effective=(g==0)?256:g;r=p;b=(p*37)%256;
   expected_r=q8(swap?b:r,effective);
   expected_g=q8(255-p,effective);
   expected_b=q8(swap?r:b,effective);
   @(posedge clk);#1;
   if(result!=={expected_r[7:0],expected_g[7:0],expected_b[7:0]} || result_valid!==valid || result_fs!==frame_start ||
      parameter_swap[23:16]!==q8(b,effective) ||
      parameter_swap[15:8]!==q8(255-p,effective) ||
      parameter_swap[7:0]!==q8(r,effective)) begin
    if(errors<5)$display("FAIL: Q8 pixel=%0d gain=%0d rgb=%h output=%h",p,g,rgb,result);
    errors=errors+1;
   end
  end
 end
 if(errors==0)$display("TEST_RESULT PASS color_correct_q8_exhaustive");
 else $display("TEST_RESULT FAIL color_correct errors=%0d",errors);
 $finish;
end
endmodule
