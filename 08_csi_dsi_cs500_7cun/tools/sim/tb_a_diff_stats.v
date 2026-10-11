// A1 差分验证: 新 cvp_frame_stats(LUTRAM 直方图) vs gold(原寄存器版)。
// 两实例同激励逐帧跑, 在 o_done 拍比对全部输出; 覆盖: 第 1 帧黑/白点、
// valid 中断流、i_awb_en 切换、满量程/全零/均匀/随机场景、X 传播。
`timescale 1ns/1ps
 module tb_a_diff_stats;
 localparam W=128,H=72,PIXELS=W*H;
 reg clk=0,rst=0,v=0,sof=0,eof=0,en=1;
 reg [23:0] rgb=0,raw=0;
 always #5 clk=~clk;

 wire d_done,g_done,d_ovr,g_ovr;
 wire [7:0] d_mean,g_mean,d_black,g_black,d_white,g_white;
 wire [10:0] d_r,g_r,d_g,g_g,d_b,g_b;
 wire [1:0] d_state,g_state;
 wire [31:0] d_samples,g_samples,d_neutral,g_neutral,d_clip,g_clip;
 wire [7:0] d_reason,g_reason; wire [3:0] d_regions,g_regions;

 cvp_frame_stats      #(.W(W),.H(H)) dut (.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_eof(eof),
  .i_rgb(rgb),.i_raw_rgb(raw),.i_awb_en(en),.o_done(d_done),.o_mean(d_mean),.o_black(d_black),.o_white(d_white),
  .o_awb_r(d_r),.o_awb_g(d_g),.o_awb_b(d_b),.o_awb_state(d_state),.o_samples(d_samples),.o_neutral(d_neutral),
  .o_clipped(d_clip),.o_stat_overrun(d_ovr),.o_awb_reason(d_reason),.o_awb_regions(d_regions));
 cvp_frame_stats_gold #(.W(W),.H(H)) gold(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_eof(eof),
  .i_rgb(rgb),.i_raw_rgb(raw),.i_awb_en(en),.o_done(g_done),.o_mean(g_mean),.o_black(g_black),.o_white(g_white),
  .o_awb_r(g_r),.o_awb_g(g_g),.o_awb_b(g_b),.o_awb_state(g_state),.o_samples(g_samples),.o_neutral(g_neutral),
  .o_clipped(g_clip),.o_stat_overrun(g_ovr),.o_awb_reason(g_reason),.o_awb_regions(g_regions));

 integer errors=0,frames=0;
 integer f,seed=32'h12345678;
 reg [31:0] rnd;
 reg [7:0] base_r,base_g,base_b,amp;
 integer mode,gap,p;

 function [31:0] prng;input [31:0] s;begin prng={s[6:0],s[15:0],s[22:16]}^({s[6:0],s[15:0],s[22:16]}<<9)^(s[31:23]);end endfunction

 // 随机一帧: mode 0=均匀随机 1=单色平坦 2=双峰 3=渐变 4=过曝+暗部混合
 task one_frame;input [7:0] m;
 begin
  mode=m;
  gap=(prng(seed)%7)==0;             // 1/7 概率本帧行间插 valid 断流
  for(p=0;p<PIXELS;p=p+1)begin
   @(negedge clk);
   seed=prng(seed);rnd=seed;
   v=1;sof=(p==0);eof=(p==PIXELS-1);
   case(mode)
    0:begin rgb={rnd[7:0],rnd[15:8],rnd[23:16]};raw=rgb;end
    1:begin rgb={base_r,base_g,base_b};raw=rgb;end
    2:begin rgb=rnd[24]?{base_r+amp,base_g,base_b}:{base_r,base_g,base_b+amp};raw=rgb;end
    3:begin rgb={rnd[7:0],8'd120,(rnd[15:8]*3)>>4};raw={rnd[15:8],8'd120,rnd[23:16]};end
    4:begin rgb=rnd[25:24]==0?24'hffffff:(rnd[25:24]==1?24'h000000:{rnd[7:0],rnd[15:8],rnd[23:16]});raw=rgb;end
   endcase
   if(gap&&p%17==0)begin v=0;@(negedge clk);v=1;end
  end
  @(negedge clk);v=0;sof=0;eof=0;
  // 等两路 done 同拍出现后比对
  fork
   wait(d_done);wait(g_done);
  join
  @(negedge clk);
  frames=frames+1;
  if(d_done!==g_done)begin errors=errors+1;$display("F%0d done misalign",frames);end
  if(d_mean!==g_mean||d_black!==g_black||d_white!==g_white)begin
   errors=errors+1;$display("F%0d m%d/%d bk%d/%d wh%d/%d",frames,d_mean,g_mean,d_black,g_black,d_white,g_white);end
  if(d_r!==g_r||d_g!==g_g||d_b!==g_b)begin
   errors=errors+1;$display("F%0d gain %d/%d %d/%d %d/%d",frames,d_r,g_r,d_g,g_g,d_b,g_b);end
  if(d_state!==g_state||d_samples!==g_samples||d_neutral!==g_neutral||d_clip!==g_clip)begin
   errors=errors+1;$display("F%0d st%d/%d s%d/%d n%d/%d c%d/%d",frames,d_state,g_state,d_samples,g_samples,d_neutral,g_neutral,d_clip,g_clip);end
  if(d_ovr!==g_ovr||d_reason!==g_reason||d_regions!==g_regions)begin
   errors=errors+1;$display("F%0d ovr%d/%d rs%d/%d rg%d/%d",frames,d_ovr,g_ovr,d_reason,g_reason,d_regions,g_regions);end
  if((^d_mean)===1'bx||(^d_black)===1'bx||(^d_white)===1'bx||(^d_r)===1'bx||(^d_b)===1'bx)begin
   errors=errors+1;$display("F%0d X detected",frames);end
  if(d_ovr)begin errors=errors+1;$display("F%0d overrun!",frames);end
 end endtask

 initial begin
  #31;rst=1;
  #400; // LUTRAM 上电旋转清扫 >=32 拍
  // 场景序列: 每种多帧, base/amp 每帧换
  for(f=0;f<4;f=f+1)begin seed=prng(seed);base_r=seed[7:0];base_g=seed[15:8];base_b=seed[23:16];amp=seed[31:24]|8'd4;one_frame(1);end
  en=0;
  for(f=0;f<3;f=f+1)begin seed=prng(seed);base_r=seed[7:0];base_g=seed[15:8];base_b=seed[23:16];amp=seed[31:24]|8'd4;one_frame(0);end
  en=1;
  for(f=0;f<6;f=f+1)begin seed=prng(seed);base_r=seed[7:0];base_g=seed[15:8];base_b=seed[23:16];amp=seed[31:24]|8'd4;one_frame(f%4==0?4:f%4==1?2:f%4==2?3:0);end
  one_frame(1);one_frame(1);   // 连续相同平坦帧(考察帧间清扫完备)
  one_frame(4);                // 全黑帧( hist[0] 满帧)
  one_frame(0);
  if(errors==0)$display("TEST_RESULT PASS diff_stats %0d frames",frames);
  else $display("TEST_RESULT FAIL diff_stats %0d errors in %0d frames",errors,frames);
  $finish;
 end
 initial begin #80000000;$display("TEST_RESULT FAIL timeout at frame %0d",frames);$finish;end
endmodule
