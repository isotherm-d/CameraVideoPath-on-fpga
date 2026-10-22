// MLKPAI-F02: same-frame RAW10 acceptance -> final video packet completion.
// 100 MHz timestamps; the TX completion mailbox adds <0.1 us of CDC delay.
// Five digits show milliseconds with three fractional digits, then two blank
// positions and the actual video mode 0..6. Example: "24.053  3".
module cvp_latency_display #(
 parameter CLK_HZ=100000000, UPDATE_MS=200, STALE_MS=1000,
 parameter SPI_HALF=50, SLOT_CYCLES=12500
)(
 input clk,rst_n,input [31:0] i_ticks,input i_capture,
 input i_frame_sof,input [31:0] i_frame_id,input [2:0] i_mode,
 input net_clk,net_rst_n,i_tx_done,input [31:0] i_tx_frame,
 output o_sclk,o_data,o_latch,
 output reg o_sample,output reg [31:0] o_latency_ticks,o_latency_us,
 output reg [31:0] o_bcd,output reg o_valid
);
 localparam TICKS_PER_US=CLK_HZ/1000000;
 localparam REM_W=TICKS_PER_US>1?$clog2(TICKS_PER_US+1):1;
 localparam UPDATE_CYCLES=(CLK_HZ/1000)*UPDATE_MS;
 localparam STALE_CYCLES=(CLK_HZ/1000)*STALE_MS;
 reg [31:0] pending_tick;reg pending_valid;
 reg [31:0] capture_tick[0:7],capture_tag[0:7];reg [7:0] capture_valid;
 wire tx_valid;wire [31:0] tx_frame;
 cvp_mailbox #(.DW(32)) tx_event(
  .s_clk(net_clk),.s_rst_n(net_rst_n),.s_valid(i_tx_done),.s_data(i_tx_frame),.s_ready(),
  .m_clk(clk),.m_rst_n(rst_n),.m_valid(tx_valid),.m_data(tx_frame),.m_ready(1'b1));
 wire [2:0] slot=tx_frame[2:0];
 wire [31:0] delta=i_ticks-capture_tick[slot];
 wire matched=tx_valid&&capture_valid[slot]&&capture_tag[slot]==tx_frame&&delta<STALE_CYCLES;
 reg [31:0] refresh,age;
 reg [1:0] state;reg [5:0] step;
 reg [31:0] dividend,quotient,binary,bcd;
 reg [REM_W-1:0] remainder;
 wire [REM_W:0] trial={remainder,dividend[31]};
 wire take_bit=trial>=TICKS_PER_US;
 wire [31:0] next_quotient={quotient[30:0],take_bit};
 reg [31:0] adjusted;integer digit,k;
 always @* begin
  adjusted=bcd;
  for(digit=0;digit<8;digit=digit+1)
   if(bcd[digit*4+:4]>=5)adjusted[digit*4+:4]=bcd[digit*4+:4]+4'd3;
 end
 wire [31:0] next_bcd={adjusted[30:0],binary[31]};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending_tick<=0;pending_valid<=0;capture_valid<=0;
   for(k=0;k<8;k=k+1)begin capture_tick[k]<=0;capture_tag[k]<=0;end
  end else begin
   if(tx_valid&&capture_tag[slot]==tx_frame)capture_valid[slot]<=0;
   if(i_capture)begin pending_tick<=i_ticks;pending_valid<=1;end
   // Bind the capture timestamp to the actual RGB frame ID, never a guessed ID.
   if(i_frame_sof)begin
    capture_tick[i_frame_id[2:0]]<=i_capture?i_ticks:pending_tick;
    capture_tag[i_frame_id[2:0]]<=i_frame_id;
    capture_valid[i_frame_id[2:0]]<=pending_valid||i_capture;
    pending_valid<=0;
   end
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   refresh<=0;age<=STALE_CYCLES;state<=0;step<=0;
   dividend<=0;quotient<=0;binary<=0;bcd<=0;remainder<=0;
   o_sample<=0;o_latency_ticks<=0;o_latency_us<=0;o_bcd<=0;o_valid<=0;
  end else begin
   o_sample<=0;
   if(refresh!=0)refresh<=refresh-1'b1;
   if(age<STALE_CYCLES)age<=age+1'b1;
   else o_valid<=0;
   case(state)
    0:if(matched&&refresh==0)begin
     o_latency_ticks<=delta;dividend<=delta;quotient<=0;remainder<=0;
     step<=0;state<=1;refresh<=UPDATE_CYCLES;
    end
    // Serial unsigned division: no combinational divider or DSP allocation.
    1:begin
     dividend<={dividend[30:0],1'b0};quotient<=next_quotient;
     remainder<=take_bit?trial-TICKS_PER_US:trial;
     if(step==31)begin binary<=next_quotient;o_latency_us<=next_quotient;bcd<=0;step<=0;state<=2;end
     else step<=step+1'b1;
    end
    2:begin
     binary<={binary[30:0],1'b0};bcd<=next_bcd;
     if(step==31)begin o_bcd<=next_bcd;o_valid<=1;o_sample<=1;age<=0;state<=0;end
     else step<=step+1'b1;
    end
    default:state<=0;
   endcase
  end
 end
 cvp_hc595_scan #(.SPI_HALF(SPI_HALF),.SLOT_CYCLES(SLOT_CYCLES)) scan(
  .clk(clk),.rst_n(rst_n),.i_bcd(o_bcd),.i_valid(o_valid),.i_mode(i_mode),
  .o_sclk(o_sclk),.o_data(o_data),.o_latch(o_latch));
endmodule

// Vendor F02 wiring: shift active-high digit select first, active-low segments
// second, MSB first. Board feedback: digit 0 is rightmost (select 0x80),
// while select 0x01 is leftmost. Bit 7 of the segment byte is the decimal dot.
module cvp_hc595_scan #(parameter SPI_HALF=50,SLOT_CYCLES=12500)(
 input clk,rst_n,input [31:0] i_bcd,input i_valid,input [2:0] i_mode,
 output reg o_sclk,output o_data,output reg o_latch
);
 localparam DIV_W=SPI_HALF>1?$clog2(SPI_HALF):1;
 localparam SLOT_W=SLOT_CYCLES>1?$clog2(SLOT_CYCLES):1;
 reg [DIV_W-1:0] divider;reg [SLOT_W-1:0] slot_timer;
 reg [15:0] shift;reg [5:0] phase;reg active;
 reg [2:0] index;reg [31:0] held_bcd;reg held_valid;
 // Physical left-to-right: five latency digits, two blanks, one mode digit.
 // Overflow is unavailable rather than silently wrapping above 99.999 ms.
 wire [31:0] incoming={i_bcd[19:0],8'h00,1'b0,i_mode};
 wire incoming_valid=i_valid&&i_bcd[31:20]==0;
 wire [31:0] value=index==0?incoming:held_bcd;
 wire valid=index==0?incoming_valid:held_valid;
 wire [3:0] number=value>>(index*4);
 reg higher;integer n;
 always @* begin
  higher=0;
  for(n=0;n<8;n=n+1)if(n>=index&&value[n*4+:4]!=0)higher=1;
 end
 function [7:0] segments;input [3:0] x;
  begin case(x)
   0:segments=8'hc0;1:segments=8'hf9;2:segments=8'ha4;3:segments=8'hb0;
   4:segments=8'h99;5:segments=8'h92;6:segments=8'h82;7:segments=8'hf8;
   8:segments=8'h80;9:segments=8'h90;default:segments=8'hff;
  endcase end
 endfunction
 wire [7:0] pattern=index==0?(number<=6?segments(number):8'hbf):
                     index<3?8'hff:!valid?8'hbf:(index>6&&!higher)?8'hff:
                     segments(number)&(index==6?8'h7f:8'hff);
 assign o_data=shift[15];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   divider<=0;slot_timer<=0;shift<=0;phase<=0;active<=0;
   index<=0;held_bcd<=0;held_valid<=0;o_sclk<=0;o_latch<=0;
  end else begin
   if(slot_timer!=0)slot_timer<=slot_timer-1'b1;
   if(!active)begin
    if(slot_timer==0)begin
     shift<={(8'h80>>index),pattern};phase<=0;active<=1;
     divider<=SPI_HALF-1;slot_timer<=SLOT_CYCLES-1;
     if(index==0)begin held_bcd<=incoming;held_valid<=incoming_valid;end
    end
   end else if(divider==0)begin
    divider<=SPI_HALF-1;
    if(phase<32)begin
     o_sclk<=!phase[0];
     if(phase[0])shift<={shift[14:0],1'b0};
     phase<=phase+1'b1;
    end else if(phase==32)begin o_latch<=1;phase<=33;end
    else begin o_latch<=0;active<=0;index<=index+1'b1;end
   end else divider<=divider-1'b1;
  end
 end
endmodule
