`timescale 1ns/1ps
module tb_opt_tone;
 reg clk=0,rst=0,v=0,sof=0,en=0,stats=0;
 reg [23:0] rgb=0;reg [7:0] black=0,white=0;
 reg [31:0] rng=32'h57344ca1;
 always #5 clk=~clk;
 wire dv,ds,gv,gs;wire [23:0] dr,gr;
 cvp_tone dut(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_rgb(rgb),.i_en(en),
 .i_stats_done(stats),.i_black(black),.i_white(white),.o_valid(dv),.o_sof(ds),.o_rgb(dr));
 cvp_tone_v30_gold gold(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_rgb(rgb),.i_en(en),
 .i_stats_done(stats),.i_black(black),.i_white(white),.o_valid(gv),.o_sof(gs),.o_rgb(gr));
 integer errors=0,checked=0,cases=0,b,w,j,n;
 always @(posedge clk)begin
  #1;
  if(rst)begin
   checked=checked+1;
   // Compare all output cycles and coefficients, including the update cycle.
   if(dv!==gv||ds!==gs||dr!==gr||dut.pending_gain!==gold.pending_gain||dut.pending_offset!==gold.pending_offset||
      dut.active_gain!==gold.active_gain||dut.active_offset!==gold.active_offset)begin
    if(errors<5)$display("tone difference black=%0d white=%0d @%0t rgb=%h/%h pending=%0d/%0d",black,white,$time,dr,gr,dut.pending_gain,gold.pending_gain);
    errors=errors+1;
   end
  end
 end
 task random_pixel;begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};rgb=rng[23:0];v=rng[5:3]!=0;en=rng[7];sof=rng[11:8]==0;
 end endtask
 initial begin
  #31;rst=1;
  // All 65536 black/white combinations, including every legal divisor and
  // black offset, inverted ranges and the bypass boundary at 24/25.
  for(b=0;b<256;b=b+1)for(w=0;w<256;w=w+1)begin
   @(negedge clk);black=b;white=w;stats=1;random_pixel();
   for(j=0;j<45;j=j+1)begin @(negedge clk);stats=0;random_pixel();end
   cases=cases+1;
  end
  // Exercise ignored starts while busy, simultaneous completions/requests,
  // arbitrary SOF timing and reset during a calculation.
  for(n=0;n<4096;n=n+1)begin
   @(negedge clk);random_pixel();black=rng[15:8];white=rng[23:16];stats=rng[1:0]!=0;
   if(n%257==0)rst=0;else rst=1;
  end
  @(negedge clk);stats=0;rst=1;repeat(50)@(negedge clk);
  if(errors==0&&cases==65536)$display("TEST_RESULT PASS tone_v30_exact_equivalence cases=%0d cycles=%0d",cases,checked);
  else $display("TEST_RESULT FAIL tone errors=%0d cases=%0d",errors,cases);
  $finish;
 end
 initial begin #40000000;$display("TEST_RESULT FAIL tone timeout");$finish;end
endmodule
