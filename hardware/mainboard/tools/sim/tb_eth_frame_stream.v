`timescale 1ns/1ps
// Actual pixel FIFO, byte serializer, byte FIFO, credit and GMII packet builder.
// A partial stream precedes SOF; packet payload must start at the real frame.
module tb_eth_frame_stream;
localparam W=16,H=8,DB=12,PPF=32;
reg pc=0,gc=0,rst=0,valid=0,sof=0;
always #5 pc=~pc;
always #4 gc=~gc;
reg [95:0] pixels=0;
integer frame,group,p,warm,packets=0,position=0,errors=0,checked=0,idx,expected;
reg last_en=0;
reg [47:0] app=0;
reg [7:0] byte_value;
cvp_eth_dbg #(.IMG_W(W),.IMG_H(H),.FRAME_SKIP(1),.DATA_BYTES(DB),.GEN_TESTPAT(0)) dut(
 .i_clk_pix(pc),.i_rst_pix_n(rst),.i_valid(valid),.i_rgb(pixels),.i_tuser(sof),
 .i_clk_100m(pc),.i_rst_100m_n(rst),.i_clk_gmii(gc),.i_rst_gmii_n(rst),
 .i_txd_swap(1'b0),.i_dbg_flags(16'd0),.i_scan_word(16'd0),.i_eth_mdio_i(1'b1),
 .o_scan_rotate(),.o_rgmii_txd(),.o_rgmii_tx_ctl(),.o_rgmii_txc(),
 .o_eth_mdc(),.o_eth_mdio_o(),.o_eth_mdio_oe(),.o_link(),.o_act(),.o_ext_dly());
// Default 720p counter must represent every one of 2,764,800 bytes.
cvp_eth_dbg #(.FRAME_SKIP(1),.GEN_TESTPAT(0)) width_check(
 .i_clk_pix(pc),.i_rst_pix_n(rst),.i_valid(1'b0),.i_rgb(96'd0),.i_tuser(1'b0),
 .i_clk_100m(pc),.i_rst_100m_n(rst),.i_clk_gmii(gc),.i_rst_gmii_n(rst),
 .i_txd_swap(1'b0),.i_dbg_flags(16'd0),.i_scan_word(16'd0),.i_eth_mdio_i(1'b1),
 .o_scan_rotate(),.o_rgmii_txd(),.o_rgmii_tx_ctl(),.o_rgmii_txc(),
 .o_eth_mdc(),.o_eth_mdio_o(),.o_eth_mdio_oe(),.o_link(),.o_act(),.o_ext_dly());
function [23:0] pixel(input integer f,n);
reg [7:0] r,g,b;
begin r=f+1;g=n;b=255-n;pixel={r,g,b};end
endfunction
always @(negedge gc)begin
 if(dut.u_mac.r_tx_en)begin
  if(!last_en)begin position=0;app=0;end
  byte_value=dut.u_mac.r_tx_byte;
  if(position>=50 && position<56)app={app[39:0],byte_value};
  if(position>=56 && position<56+DB)begin
   idx=(packets%PPF)*DB+position-56;
   case(idx%3)
    0:expected=packets/PPF+1;
    1:expected=idx/3;
    2:expected=255-idx/3;
   endcase
   if(byte_value!==expected[7:0])begin
    if(errors<6)$display("FAIL: packet=%0d byte=%0d got=%0d expected=%0d",packets,idx,byte_value,expected);
    errors=errors+1;
   end
   checked=checked+1;
  end
  position=position+1;
 end else if(last_en)begin
  if(app[47:40]!==packets/PPF || app[39:32]!==8'd1 || app[31:0]!==((packets%PPF)*DB))begin
   $display("FAIL: application header packet=%0d header=%h",packets,app);errors=errors+1;
  end
  packets=packets+1;
 end
 last_en=dut.u_mac.r_tx_en;
end
initial begin
 #100;rst=1;
 if(width_check.PX_LAST!==22'd2764799)begin $display("FAIL: 720p byte counter truncation");errors=errors+1;end
 // More than a small frame of garbage without SOF must produce no packet.
 for(warm=0;warm<64;warm=warm+1)begin
  @(negedge pc);valid=1;sof=0;pixels={4{24'habcdef}};
  @(negedge pc);valid=0;repeat(4)@(negedge pc);
 end
 repeat(300)@(negedge gc);
 if(packets!=0)begin $display("FAIL: transmission began before real SOF");errors=errors+1;end
 for(frame=0;frame<3;frame=frame+1)begin
  for(group=0;group<PPF;group=group+1)begin
   @(negedge pc);valid=1;sof=(group==0);
   for(p=0;p<4;p=p+1)pixels[95-p*24-:24]=pixel(frame,group*4+p);
   @(negedge pc);valid=0;sof=0;repeat(4)@(negedge pc);
  end
 end
 repeat(30000)@(negedge gc);
 if(errors==0 && packets==96 && checked==1152)$display("TEST_RESULT PASS complete_ethernet_frame_stream");
 else $display("TEST_RESULT FAIL ethernet_stream errors=%0d packets=%0d bytes=%0d",errors,packets,checked);
 $finish;
end
endmodule
