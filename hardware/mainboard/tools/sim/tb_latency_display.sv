`timescale 1ns/1ps
module tb_latency_display;
 reg clk=0;always #5 clk=~clk;
 reg net_clk=0;always #4 net_clk=~net_clk;
 reg rst=0,nrst=0,capture=0,sof=0,done=0;
 reg [31:0] ticks=0,fid=0,tx_fid=0;
 wire sample,valid,sclk,data,latch;wire [31:0] latency_ticks,us,bcd;
 cvp_latency_display #(.UPDATE_MS(0),.STALE_MS(100),.SPI_HALF(2),.SLOT_CYCLES(100)) dut(
  .clk(clk),.rst_n(rst),.i_ticks(ticks),.i_capture(capture),.i_frame_sof(sof),.i_frame_id(fid),.i_mode(3'd0),
  .net_clk(net_clk),.net_rst_n(nrst),.i_tx_done(done),.i_tx_frame(tx_fid),
  .o_sclk(sclk),.o_data(data),.o_latch(latch),.o_sample(sample),
  .o_latency_ticks(latency_ticks),.o_latency_us(us),.o_bcd(bcd),.o_valid(valid));
 integer checks=0,samples=0;
 always @(posedge clk)if(rst&&sample)samples=samples+1;
 function [31:0] reference_bcd(input [31:0] value);
  reg [31:0] q;begin
   q=value;reference_bcd=0;
   for(integer n=0;n<8;n=n+1)begin reference_bcd[n*4+:4]=q%10;q=q/10;end
  end
 endfunction
 task start_frame(input [31:0] id,stamp);
  @(negedge clk);ticks=stamp;capture=1;
  @(negedge clk);capture=0;
  repeat(4)@(negedge clk);
  fid=id;sof=1;
  @(negedge clk);sof=0;
 endtask
 task finish_frame(input [31:0] id,stamp);
  @(negedge clk);ticks=stamp;
  @(negedge net_clk);tx_fid=id;done=1;
  @(negedge net_clk);done=0;
 endtask
 task expect_delay(input [31:0] id,stamp,delta);
  integer previous;begin
   start_frame(id,stamp);previous=samples;
   finish_frame(id,stamp+delta);
   repeat(100)@(negedge clk);
   if(samples!=previous+1||!valid||latency_ticks!==delta||us!==delta/100||bcd!==reference_bcd(delta/100))
    $fatal(1,"delay mismatch frame=%h ticks=%d expected=%d us=%d bcd=%h",id,latency_ticks,delta,us,bcd);
   checks=checks+1;
  end
 endtask
 initial begin
  repeat(6)@(negedge clk);rst=1;nrst=1;
  if(valid!==0)$fatal(1,"startup must show unavailable");
  expect_delay(0,1000,0);expect_delay(1,3000,99);
  expect_delay(2,5000,100);expect_delay(3,8000,9999999);
  // Timestamp and frame-ID wrap, with exact decimal conversion.
  expect_delay(32'hffffffff,32'hfffffff0,12345);
  expect_delay(0,20000,2405399);
  for(integer n=0;n<60;n=n+1)expect_delay(n+20,n*1234567,(n*154301)%9999999);
  // A late ID with a reused ring slot must not match the newer frame.
  start_frame(100,0);start_frame(108,100);
  begin integer previous;previous=samples;
   finish_frame(100,200);repeat(100)@(negedge clk);
   if(samples!=previous)$fatal(1,"reused timestamp slot accepted stale frame");
   checks=checks+1;
  end
  finish_frame(108,500);repeat(100)@(negedge clk);
  if(us!==4)$fatal(1,"matched new frame incorrectly");
  begin integer previous;previous=samples;
   finish_frame(108,600);repeat(100)@(negedge clk);
   if(samples!=previous)$fatal(1,"duplicate TX reused consumed timestamp");
   checks=checks+1;
  end
  // RGB SOF without a corresponding RAW10 capture cannot produce a measurement.
  @(negedge clk);fid=200;sof=1;@(negedge clk);sof=0;
  begin integer previous;previous=samples;
   finish_frame(200,800);repeat(100)@(negedge clk);
   if(samples!=previous)$fatal(1,"missing capture was accepted");
   checks=checks+1;
  end
  start_frame(210,1000);
  begin integer previous;previous=samples;
   finish_frame(210,10001000);repeat(100)@(negedge clk);
   if(samples!=previous)$fatal(1,"expired capture accepted");
   checks=checks+1;
  end
  repeat(10000100)@(negedge clk);
  if(valid!==0)$fatal(1,"stale latency still displayed as current");
  $display("TEST_RESULT PASS tb_latency_display checks=%0d CDC frame binding wrap divide BCD stale alias duplicate",checks);
  $finish;
 end
 initial begin #200000000;$fatal(1,"timeout");end
endmodule

module tb_hc595_scan;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,valid=0;reg [31:0] bcd=32'h00024053;reg [2:0] mode=3;
 wire sclk,data,latch;
 cvp_hc595_scan #(.SPI_HALF(2),.SLOT_CYCLES(100)) dut(
  .clk(clk),.rst_n(rst),.i_bcd(bcd),.i_valid(valid),.i_mode(mode),.o_sclk(sclk),.o_data(data),.o_latch(latch));
 reg [15:0] shifted=0;integer bits=0,words=0,column,mode_expected;reg [7:0] expected,mode_segment;
 reg [7:0] panel[0:7];reg [7:0] seen_select=0;
 reg [63:0] expected_panel;
 always @(posedge sclk)begin shifted={shifted[14:0],data};bits=bits+1;end
 always @(posedge latch)begin
  if(bits!=16)$fatal(1,"595 latch without 16 serial clocks: %0d",bits);
  // Physical panel, left to right, as established by board feedback.
  // Decode the serial pin traffic into physical positions independently of
  // the DUT scan index, then check the complete human-readable panel.
  case(shifted[15:8])
   8'h01:column=0;8'h02:column=1;8'h04:column=2;8'h08:column=3;
   8'h10:column=4;8'h20:column=5;8'h40:column=6;8'h80:column=7;
   default:$fatal(1,"non one-hot physical digit select %h",shifted);
  endcase
  if(seen_select&shifted[15:8])$fatal(1,"duplicate digit in scan");
  seen_select=seen_select|shifted[15:8];panel[column]=shifted[7:0];
  mode_expected=words>=96?2:words<24?3:words<32?6:words/8-4;
  case(mode_expected)
   0:mode_segment=8'hc0;1:mode_segment=8'hf9;2:mode_segment=8'ha4;3:mode_segment=8'hb0;
   4:mode_segment=8'h99;5:mode_segment=8'h92;6:mode_segment=8'h82;default:mode_segment=8'hbf;
  endcase
  // Literal physical left-to-right fixtures, independent of scan index.
  if(words<8 || (words>=24&&words<32))expected_panel={40'hbfbfbfbfbf,16'hffff,mode_segment};
  else if(words<96)expected_panel={40'ha419c092b0,16'hffff,mode_segment};
  else case((words-96)/8)
   0:expected_panel=64'hff40c0c0c0ffffa4; // 0.000, two blanks, mode 2
   1:expected_panel=64'hff40c0c0f9ffffa4; // 0.001
   2:expected_panel=64'h9010909090ffffa4; // 99.999
   default:expected_panel=64'hbfbfbfbfbfffffa4; // overflow, no truncation
  endcase
  expected=expected_panel>>((7-column)*8);
  if(shifted[7:0]!==expected)$fatal(1,"segments mismatch word=%d got=%h expected=%h",words,shifted,expected);
  if(words%8==7)begin
   if(seen_select!==8'hff)$fatal(1,"incomplete physical panel");
   if(panel[7]!==mode_segment)$fatal(1,"rightmost physical digit must show mode without decimal point");
   if(panel[5]!==8'hff||panel[6]!==8'hff)$fatal(1,"two separator positions must always be blank");
   if({panel[0],panel[1],panel[2],panel[3],panel[4],panel[5],panel[6],panel[7]}!==expected_panel)
    $fatal(1,"five latency digits, two blanks, one mode: got unexpected physical panel");
   seen_select=0;
  end
  words=words+1;bits=0;
 end
 initial begin
  repeat(6)@(negedge clk);rst=1;
  wait(words==8);@(negedge clk);valid=1;
  wait(words==17);@(negedge clk);valid=0;bcd=32'h99999999;mode=6;
  // The in-progress scan retains the complete old value through word 23.
  wait(words==32);@(negedge clk);valid=1;bcd=32'h00024053;
  for(integer m=0;m<8;m=m+1)begin
   mode=m;wait(words==(m+5)*8);@(negedge clk);
  end
  mode=2;bcd=0;wait(words==104);@(negedge clk);
  bcd=1;wait(words==112);@(negedge clk);
  bcd=32'h00099999;wait(words==120);@(negedge clk);
  bcd=32'h00100000;wait(words==128);@(negedge clk);
  bcd=32'h12345678;wait(words==136);@(negedge clk);
  $display("TEST_RESULT PASS tb_hc595_scan 136 words five latency digits two blanks mode 0..6 boundary overflow atomic snapshot");$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
