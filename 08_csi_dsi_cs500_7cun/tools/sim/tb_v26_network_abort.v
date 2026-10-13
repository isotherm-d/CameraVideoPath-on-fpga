`timescale 1ns/1ps
// Short frame followed by healthy frames: packet IDs/offsets must not splice.
module tb_v26_network_abort;
 localparam W=16,H=4,DB=48,PPF=4;
 reg pc=0,gc=0,rst=0,v=0,sof=0;always #5 pc=~pc;always #4 gc=~gc;
 reg [95:0] pixels;reg [31:0] fid;wire overflow,done;wire [31:0] done_id;
 cvp_eth_dbg #(.IMG_W(W),.IMG_H(H),.FRAME_SKIP(1),.DATA_BYTES(DB),.GEN_TESTPAT(0),.ENABLE_STATUS(1)) dut(
  .i_clk_pix(pc),.i_rst_pix_n(rst),.i_valid(v),.i_rgb(pixels),.i_tuser(sof),.i_frame_id(fid),
  .i_status_data(1024'd0),.i_status_valid(1'b0),.o_status_ready(),.o_pixel_overflow(overflow),
  .o_frame_tx_done(done),.o_frame_tx_id(done_id),.i_clk_100m(pc),.i_rst_100m_n(rst),.i_clk_gmii(gc),.i_rst_gmii_n(rst),
  .i_txd_swap(1'b0),.i_dbg_flags(16'd0),.i_scan_word(16'd0),.i_eth_mdio_i(1'b1),
  .o_scan_rotate(),.o_rgmii_txd(),.o_rgmii_tx_ctl(),.o_rgmii_txc(),.o_eth_mdc(),.o_eth_mdio_o(),.o_eth_mdio_oe(),.o_link(),.o_act(),.o_ext_dly());
 integer position=0,packets=0,errors=0,p,g,f,idx,expect,full_a=0,full_c=0,full_d=0,full_e=0,full_f=0,gap=1500;
 reg last=0;reg [47:0] app;reg [7:0] byte_value;
 function [23:0] pixel;input integer frame,n;begin pixel={frame[7:0],n[7:0],8'd255-n[7:0]};end endfunction
 always @(negedge gc)begin
  if(dut.u_mac.r_tx_en)begin
   if(!last)begin position=0;app=0;end
   byte_value=dut.u_mac.r_tx_byte;
   if(position>=50&&position<56)app={app[39:0],byte_value};
   if(position>=56&&position<56+DB&&app[39:32]==1)begin
    idx=app[31:0]+position-56;
    case(idx%3)0:expect=app[47:40];1:expect=idx/3;2:expect=255-idx/3;endcase
    if(byte_value!==expect[7:0])begin errors=errors+1;if(errors<5)$display("SPLICE fid=%0d off=%0d byte=%0d got=%0d expected=%0d",app[47:40],app[31:0],idx,byte_value,expect);end
   end
   position=position+1;
  end else if(last&&app[39:32]==1)begin
   packets=packets+1;
   if(app[47:40]==10)full_a=full_a+1;
   if(app[47:40]==12)full_c=full_c+1;
   if(app[47:40]==13)full_d=full_d+1;
   if(app[47:40]==24)full_e=full_e+1;
   if(app[47:40]==96)full_f=full_f+1;
  end
  if(overflow)errors=errors+1;
  if(dut.descriptor_write&&!dut.desc_ready)begin errors=errors+1;$display("FAIL descriptor overflow");end
  last=dut.u_mac.r_tx_en;
 end
 task image;input integer frame,groups;begin
  for(g=0;g<groups;g=g+1)begin
   @(negedge pc);v=1;sof=g==0;fid=frame;
   for(p=0;p<4;p=p+1)pixels[95-p*24-:24]=pixel(frame,g*4+p);
   @(negedge pc);v=0;sof=0;repeat(4)@(negedge pc);
  end
  repeat(gap)@(negedge pc);
 end endtask
 initial begin
  #100;rst=1;image(10,16);image(11,13);image(12,16);image(13,16);
  image(20,1);image(21,4);image(22,15);image(23,2);image(24,18);
  gap=0;for(f=32;f<96;f=f+1)image(f,1);image(96,16);
  repeat(10000)@(negedge gc);
  if(errors==0&&full_a==4&&full_c==4&&full_d==4&&full_e==4&&full_f==4&&done_id==96)
   $display("TEST_RESULT PASS packet_frame_identity_after_short_frame packets=%0d",packets);
  else $display("TEST_RESULT FAIL short_frame_splice errors=%0d packets=%0d A/C/D/E/F=%0d/%0d/%0d/%0d/%0d done=%0d",errors,packets,full_a,full_c,full_d,full_e,full_f,done_id);
  $finish;
 end
 initial begin #3000000;$display("TEST_RESULT FAIL network abort timeout");$finish;end
endmodule
