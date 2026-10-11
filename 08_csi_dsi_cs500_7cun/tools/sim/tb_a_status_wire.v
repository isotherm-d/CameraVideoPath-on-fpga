// A2 验证 2: 桥 + mac_tx 全链路。驱动已知 1536bit 状态快照, 从 RGMII
// ODDR 输出重建线上字节流, 校验: 前导/SFD、以太网/IP/UDP 头关键字节、
// 应用头、192 字节状态载荷(与快照 MSB 序一致)、FCS(CRC32)。
// 连发两个不同快照, 覆盖 bank 交替与 pop 后重新武装。
`timescale 1ns/1ps
module tb_a_status_wire;
 localparam DW=1536;
 reg clk100=0,clk125=0,rst_n=0;
 always #5 clk100=~clk100;
 always #4 clk125=~clk125;

 reg s_valid=0,m_ready=0;
 reg [DW-1:0] s_data=0;
 wire s_ready,m_valid,o_bank;
 wire [7:0] raddr;wire [15:0] rdata;
 wire [3:0] txd;wire tx_ctl,txc;
 wire pop;wire tx_pkt,hb_pkt;

 cvp_status_bridge #(.DW(DW)) bridge(
  .s_clk(clk100),.s_rst_n(rst_n),.s_valid(s_valid),.s_data(s_data),.s_ready(s_ready),
  .m_clk(clk125),.m_rst_n(rst_n),.m_valid(m_valid),.m_ready(pop),
  .i_raddr(raddr),.o_rdata(rdata),.o_bank(o_bank));

 cvp_gmii_mac_tx #(
  .ENABLE_STATUS(1),.STATUS_BITS(1536),.DATA_BYTES(1440),.PKTS_PER_FRAME(1920)
 ) mac(
  .i_clk(clk125),.i_rst(~rst_n),
  .i_status_valid(m_valid),.o_status_pop(pop),
  .i_status_rdata(rdata),.i_status_bank(o_bank),.o_status_raddr(raddr),
  .i_frame_valid(1'b0),.i_frame_id(32'd0),.o_frame_pop(),.o_frame_done(),.o_frame_done_id(),
  .i_credit_gray(7'd0),.o_rd_en(),.i_rd_empty(1'b1),.i_rd_valid(1'b0),.i_rd_data(8'd0),
  .i_txd_swap(1'b0),.i_dbg_flags(16'h5AA5),.i_scan_word(16'h1234),
  .o_rgmii_txd(txd),.o_rgmii_tx_ctl(tx_ctl),.o_rgmii_txc(txc),
  .o_tx_pkt(tx_pkt),.o_hb_pkt(hb_pkt));

 reg [7:0] expect [0:191];
 reg [DW-1:0] sent_vec;
 integer errors=0;

 // CRC32(以太网 reflected)
 function [31:0] crc32;input [7:0] d;input [31:0] c;integer k;reg [31:0] x;begin
  x=c^{24'h0,d};
  for(k=0;k<8;k=k+1)x=x[0]?((x>>1)^32'hEDB88320):(x>>1);
  crc32=x;
 end endfunction

 // 线上字节流采集: tx_pkt 触发后无条件逐周期取一对半字节
 // (posedge+1ns 低半字节, negedge+1ns 高半字节), 采 1502 对后按 55..D5
 // 前导自动对齐 —— 不用 tx_ctl 门控, 规避 ODDR 采样的半周期相位差。
 reg [7:0] frame [0:1501];
 integer nbytes=0,sn=0;
 reg [3:0] lo_n,hi_n;
 task collect_packet;integer i,o;begin
  @(posedge tx_pkt);
  for(i=0;i<1502;i=i+1)begin
   @(posedge clk125);#1;lo_n=txd;
   @(negedge clk125);#1;hi_n=txd;
   frame[i]={hi_n,lo_n};
  end
  nbytes=1500;o=-1;
  for(i=0;i<3;i=i+1)
   if(o<0&&i<8&&frame[i]==8'h55&&frame[i+7]==8'hD5)o=i;
  if(o<0)begin errors=errors+1;$display("preamble not found: %02x %02x %02x",frame[0],frame[1],frame[2]);o=0;end
  for(i=0;i<1500;i=i+1)frame[i]=frame[i+o];
 end endtask

 integer p;reg [31:0] crc;reg [7:0] b;
 task check_packet;integer i;begin
  if(nbytes!=1500)begin
   errors=errors+1;$display("len %0d != 1500",nbytes);
   $write("head:");for(i=0;i<12;i=i+1)$write(" %02x",frame[i]);$write("\n");
   $write("tail:");for(i=1490;i<1500;i=i+1)$write(" %02x",frame[i]);$write("\n");
  end
  // 前导+SFD
  for(i=0;i<7;i=i+1)if(frame[i]!=8'h55)begin errors=errors+1;$display("pre[%0d]=%02x",i,frame[i]);end
  if(frame[7]!=8'hD5)begin errors=errors+1;$display("sfd=%02x",frame[7]);end
  // MAC 头
  for(i=8;i<14;i=i+1)if(frame[i]!=8'hFF)begin errors=errors+1;$display("dst[%0d]=%02x",i,frame[i]);end
  // IP 头在 frame[22](MAC 14B): 总长 1474=0x05C2 @24,25; proto=UDP @26
  if(frame[24]!=8'h05||frame[25]!=8'hC2)begin errors=errors+1;$display("iplen %02x%02x",frame[24],frame[25]);end
  if(frame[31]!=8'h11)begin errors=errors+1;$display("proto=%02x",frame[31]);end
  // UDP 头在 frame[42]: 长度 1454=0x05AE @46,47
  if(frame[46]!=8'h05||frame[47]!=8'hAE)begin errors=errors+1;$display("udplen %02x%02x",frame[46],frame[47]);end
  // 应用头: fmt=0x26 @51
  if(frame[51]!=8'h26)begin errors=errors+1;$display("fmt=%02x",frame[51]);end
  // 状态载荷 192 字节: 与快照 MSB 序一致
  for(p=0;p<192;p=p+1)begin
   b=frame[56+p];
   if(b!==expect[p])begin errors=errors+1;$display("pay[%0d]=%02x exp %02x",p,b,expect[p]);end
  end
  // FCS
  crc=32'hFFFFFFFF;
  for(i=8;i<1496;i=i+1)crc=crc32(frame[i],crc);
  crc=~crc;
  if({frame[1499],frame[1498],frame[1497],frame[1496]}!==crc)begin
   errors=errors+1;$display("fcs got %02x%02x%02x%02x exp %08x",frame[1496],frame[1497],frame[1498],frame[1499],crc);end
 end endtask

 task make_expect;input [31:0] salt;integer w;reg [15:0] wd;begin
  sent_vec=0;
  for(w=0;w<96;w=w+1)begin
   wd=((w*16'h9E37+salt)&16'hFFFF)^(salt[15:0]);
   sent_vec[w*16+:16]=wd;
  end
  for(p=0;p<192;p=p+1)expect[p]=(p<128)?sent_vec[1023-8*p -: 8]:sent_vec[DW-1-8*(p-128) -: 8];
 end endtask

 task send_status;input [31:0] salt;begin
  make_expect(salt);
  @(negedge clk100);
  while(!s_ready)@(negedge clk100);
  s_data=sent_vec;s_valid=1;
  @(negedge clk100);s_valid=0;
 end endtask

 initial begin
  #17;rst_n=1;
  #200;
  send_status(32'h0000_00AB);
  collect_packet();sn=sn+1;
  check_packet();
  send_status(32'h0000_01CD);   // 第二个快照: 另一 bank
  collect_packet();sn=sn+1;
  check_packet();
  if(errors==0)$display("TEST_RESULT PASS status_wire_packets x%0d",sn);
  else $display("TEST_RESULT FAIL status_wire %0d errors",errors);
  $finish;
 end
 initial begin #1000000;$display("TEST_RESULT FAIL wire timeout nbytes=%0d",nbytes);$finish;end
endmodule
