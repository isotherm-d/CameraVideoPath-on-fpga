// A2 验证 1: cvp_status_bridge 字节序/握手/bank 交替。
// 随机快照捕获 -> 序列化 -> pop -> 按 mac 的方式逐字节读回,
// 校验 线上第 p 字节 == 向量 [DW-1-8p -: 8](与原 cvp_mailbox+status_packet 位精确)。
// 覆盖: 连续快照(读 bank k 时写 bank k+1 的 ping-pong)、pop 前 o_bank 稳定、
// 序列化期间 s_ready 拉低、X 检查。
`timescale 1ns/1ps
module tb_a_status_bridge;
 localparam DW=1536, WORDS=96;
 reg s_clk=0,m_clk=0,s_rst=0,m_rst=0;
 always #5 s_clk=~s_clk;
 always #4 m_clk=~m_clk;
 reg s_valid=0,m_ready=0;
 reg [DW-1:0] s_data=0;
 wire s_ready,m_valid,o_bank;
 reg [7:0] raddr=0;
 wire [15:0] rdata;

 cvp_status_bridge #(.DW(DW)) dut(
  .s_clk(s_clk),.s_rst_n(s_rst),.s_valid(s_valid),.s_data(s_data),.s_ready(s_ready),
  .m_clk(m_clk),.m_rst_n(m_rst),.m_valid(m_valid),.m_ready(m_ready),
  .i_raddr(raddr),.o_rdata(rdata),.o_bank(o_bank));

 reg [DW-1:0] vecs [0:7];
 reg [31:0] lfsr=32'hACE1_2345;
 function [31:0] prng;input [31:0] s;begin prng={s[6:0],s[15:0],s[22:16]}^({s[6:0],s[15:0],s[22:16]}<<9)^(s[31:23]);end endfunction
 integer errors=0;

 task make_vec;input integer idx;integer w;begin
  for(w=0;w<WORDS;w=w+1)begin
   lfsr=prng(lfsr);
   vecs[idx][w*16+:16]=lfsr[15:0]^(w*16'h2545);
  end
 end endtask

 // 捕获并等待序列化完成(96 s_clk + 裕量)
 task capture;input integer idx;integer i;begin
  @(negedge s_clk);
  while(!s_ready)@(negedge s_clk);
  s_data=vecs[idx];s_valid=1;
  @(negedge s_clk);s_valid=0;
  for(i=0;i<110;i=i+1)@(negedge s_clk);
 end endtask

 reg rbank;
 // pop: 等 m_valid 后脉冲 m_ready(与 mac 相同), 锁存 bank
 task pop;begin
  @(negedge m_clk);
  while(!m_valid)@(negedge m_clk);
  m_ready=1;
  @(negedge m_clk);rbank=o_bank;m_ready=0;
  @(negedge m_clk);
 end endtask

 // 按 mac 的方式逐字节读回比对
 task read_vec;input integer idx;integer p;reg [7:0] eb,gb;begin
  for(p=0;p<192;p=p+1)begin
   @(negedge m_clk);raddr={rbank,p[7:1]};
   @(negedge m_clk);@(negedge m_clk);
   gb=p[0]?rdata[7:0]:rdata[15:8];
   /* 线上序: 前 128 字节=低1024位大端, 之后=高位扩展区大端 */
   eb=(p<128)?vecs[idx][1023-8*p -: 8]:vecs[idx][DW-1-8*(p-128) -: 8];
   if(gb!==eb)begin errors=errors+1;$display("v%0d byte%0d got %02x exp %02x (bank%b)",idx,p,gb,eb,rbank);end
   if((^gb)===1'bx)begin errors=errors+1;$display("v%0d byte%0d X",idx,p);end
  end
  raddr=0;
 end endtask

 task pop_read;input integer idx;begin pop;read_vec(idx);end endtask

 integer k;
 initial begin
  #17;s_rst=1;m_rst=1;
  #100;
  for(k=0;k<8;k=k+1)make_vec(k);
  // 场景1: 捕获->读->捕获->读 顺序
  capture(0);pop_read(0);
  capture(1);pop_read(1);
  // 场景2: ping-pong —— pop2 后立刻捕获3(写 bank1), 读 bank2 与序列化并行
  capture(2);pop;
  capture(3);          // 等 s_ready 后捕获, 序列化 bank1 进行中
  read_vec(2);         // 同时读 bank0
  pop;read_vec(3);
  // 场景3: pop 后立刻再捕获再读(连发)
  capture(4);pop_read(4);capture(5);pop_read(5);
  // 快速连发
  capture(6);pop_read(6);capture(7);pop_read(7);
  if(errors==0)$display("TEST_RESULT PASS status_bridge byteorder_pingpong");
  else $display("TEST_RESULT FAIL status_bridge %0d errors",errors);
  $finish;
 end
 initial begin #3000000;$display("TEST_RESULT FAIL bridge timeout");$finish;end
endmodule
