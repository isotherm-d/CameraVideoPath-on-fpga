`timescale 1ns/1ps
module tb_v26_network;
 localparam W=16,H=16,DB=192,PPF=4;
 reg pc=0,gc=0,rst=0,v=0,sof=0,sv=0;
 always #5 pc=~pc;always #4 gc=~gc;
 reg [95:0] pixels;reg [31:0] fid;reg [1023:0] blob;
 wire sr,overflow,done;wire [31:0] done_id;
 cvp_eth_dbg #(.IMG_W(W),.IMG_H(H),.FRAME_SKIP(1),.DATA_BYTES(DB),.GEN_TESTPAT(0),.ENABLE_STATUS(1)) dut(
 .i_clk_pix(pc),.i_rst_pix_n(rst),.i_valid(v),.i_rgb(pixels),.i_tuser(sof),.i_frame_id(fid),
 .i_status_data(blob),.i_status_valid(sv),.o_status_ready(sr),.o_pixel_overflow(overflow),
 .o_frame_tx_done(done),.o_frame_tx_id(done_id),.i_clk_100m(pc),.i_rst_100m_n(rst),.i_clk_gmii(gc),.i_rst_gmii_n(rst),
 .i_txd_swap(1'b0),.i_dbg_flags(16'd0),.i_scan_word(16'd0),.i_eth_mdio_i(1'b1),
 .o_scan_rotate(),.o_rgmii_txd(),.o_rgmii_tx_ctl(),.o_rgmii_txc(),.o_eth_mdc(),.o_eth_mdio_o(),.o_eth_mdio_oe(),.o_link(),.o_act(),.o_ext_dly());
 integer frame,group,p,position=0,packets=0,video=0,statuses=0,errors=0,idx,expected,fd,byteidx;
 reg last=0;reg [47:0] app;reg [7:0] val;
 function [23:0] pixel;input integer f,n;begin pixel={8'd1+f[7:0],n[7:0],8'd255-n[7:0]};end endfunction
 always @(negedge gc)begin
  if(dut.u_mac.r_tx_en)begin
   if(!last)begin position=0;app=0;end
   val=dut.u_mac.r_tx_byte;
   $fwrite(fd,"%02x",val);
   if(position>=50&&position<56)app={app[39:0],val};
   if(position>=56&&position<56+DB)begin
    if(app[39:32]==1)begin
     idx=(video%PPF)*DB+position-56;
     case(idx%3)
      0:expected=video/PPF+1;1:expected=idx/3;2:expected=255-idx/3;
     endcase
     if(val!==expected[7:0])errors=errors+1;
    end else if(app[39:32]==8'h26)begin
     byteidx=position-56;
     if(byteidx<128&&val!==blob[(127-byteidx)*8+:8])errors=errors+1;
     if(byteidx>=128&&val!=0)errors=errors+1;
    end else errors=errors+1;
   end
   position=position+1;
  end else if(last)begin
   $fwrite(fd,"\n");
   if(app[39:32]==1)begin
    if(app[47:40]!==21+(video/PPF)*31||app[31:0]!==((video%PPF)*DB))errors=errors+1;
    video=video+1;
   end else statuses=statuses+1;
   packets=packets+1;
  end
  if(overflow)errors=errors+1;
  last=dut.u_mac.r_tx_en;
 end
 initial begin
  fd=$fopen("net_packets.hex","w");
  for(p=0;p<128;p=p+1)blob[(127-p)*8+:8]=p[7:0]^8'ha5;
  #100;rst=1;
  @(negedge pc);sv=1;@(negedge pc);sv=0;
  for(frame=0;frame<3;frame=frame+1)begin
   for(group=0;group<W*H/4;group=group+1)begin
    @(negedge pc);v=1;sof=group==0;fid=21+frame*31;
    for(p=0;p<4;p=p+1)pixels[95-p*24-:24]=pixel(frame,group*4+p);
    @(negedge pc);v=0;sof=0;repeat(3)@(negedge pc);
   end
  end
  repeat(10000)@(negedge gc);
  $fclose(fd);
  if(errors==0&&video==12&&statuses==1&&done_id==83)$display("TEST_RESULT PASS status_and_explicit_frame_identity");
  else $display("TEST_RESULT FAIL network errors%0d video%0d status%0d done%0d",errors,video,statuses,done_id);
  $finish;
 end
endmodule
