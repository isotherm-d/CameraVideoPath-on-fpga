`timescale 1ns/1ps
module tb_opt_median;
 reg clk=0,rst=0,v=0,sof=0;
 always #5 clk=~clk;
 reg [23:0] p[0:8];reg [31:0] rng=32'h31ca7701;reg [7:0] edge_value;
 wire v3,v8,vg,s3,s8,sg;wire [23:0] r3,r8,rg;
 cvp_fx_median #(.CHANNEL_BITS(3)) dut3(.i_clk(clk),.i_rst_n(rst),.i_valid(v),.i_frame_start(sof),
 .i_p00(p[0]),.i_p01(p[1]),.i_p02(p[2]),.i_p10(p[3]),.i_p11(p[4]),.i_p12(p[5]),.i_p20(p[6]),.i_p21(p[7]),.i_p22(p[8]),.o_valid(v3),.o_frame_start(s3),.o_rgb(r3));
 cvp_fx_median legacy(.i_clk(clk),.i_rst_n(rst),.i_valid(v),.i_frame_start(sof),
 .i_p00(p[0]),.i_p01(p[1]),.i_p02(p[2]),.i_p10(p[3]),.i_p11(p[4]),.i_p12(p[5]),.i_p20(p[6]),.i_p21(p[7]),.i_p22(p[8]),.o_valid(v8),.o_frame_start(s8),.o_rgb(r8));
 cvp_fx_median_v30_gold gold(.i_clk(clk),.i_rst_n(rst),.i_valid(v),.i_frame_start(sof),
 .i_p00(p[0]),.i_p01(p[1]),.i_p02(p[2]),.i_p10(p[3]),.i_p11(p[4]),.i_p12(p[5]),.i_p20(p[6]),.i_p21(p[7]),.i_p22(p[8]),.o_valid(vg),.o_frame_start(sg),.o_rgb(rg));
 integer errors=0,checked=0,n,k;
 always @(posedge clk)begin
  #1;
  if(rst)begin
   if(v3!==vg||v8!==vg)errors=errors+1;
   if(vg)begin
    checked=checked+1;
    if(s3!==sg||s8!==sg||r8!==rg||{r3[23:21],r3[15:13],r3[7:5]}!=={rg[23:21],rg[15:13],rg[7:5]})begin
     if(errors<5)$display("median difference n=%0d %h/%h/%h",n,r3,r8,rg);
     errors=errors+1;
    end
   end
  end
 end
 initial begin
  for(k=0;k<9;k=k+1)p[k]=0;
  #31;rst=1;
  for(n=0;n<100000;n=n+1)begin
   @(negedge clk);
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};v=rng[4:2]!=0;sof=n%128==0;
   for(k=0;k<9;k=k+1)begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    // Include tied quantization bins and values at bin boundaries.
    case(n%8)
     0:p[k]=24'd0;
     1:p[k]=24'hffffff;
     2:begin edge_value=127+(k%2);p[k]={3{edge_value}};end
     3:begin edge_value=31+(k%3);p[k]={3{edge_value}};end
     4:begin edge_value=224+(k%9);p[k]={3{edge_value}};end
     default:p[k]=rng[23:0];
    endcase
   end
   if(n%10007==0)rst=0;else rst=1;
  end
  @(negedge clk);v=0;sof=0;repeat(10)@(negedge clk);
  if(errors==0&&checked>50000)$display("TEST_RESULT PASS median_v30_quantized_equivalence samples=%0d",checked);
  else $display("TEST_RESULT FAIL median errors=%0d checked=%0d",errors,checked);
  $finish;
 end
 initial begin #2000000;$display("TEST_RESULT FAIL median timeout");$finish;end
endmodule
