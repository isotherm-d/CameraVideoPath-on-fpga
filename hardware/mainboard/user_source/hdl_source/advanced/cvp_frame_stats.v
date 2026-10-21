// Shared frame statistics. Snapshots include BOTH the first and last pixels.
// AE sees corrected RGB; AWB estimates absolute gains from unclipped RAW RGB.
module cvp_frame_stats #(parameter W=1280,H=720,SAFE_AWB=0)(
 input clk,rst_n,i_valid,i_sof,i_eof,input [23:0] i_rgb,i_raw_rgb,
 input i_awb_en,
 output reg o_done,output reg [7:0] o_mean,o_black,o_white,
 output reg [10:0] o_awb_r,o_awb_g,o_awb_b,output reg [1:0] o_awb_state,
 output reg [31:0] o_samples,o_neutral,o_clipped,output reg o_stat_overrun,
 output reg [7:0] o_awb_reason,output reg [3:0] o_awb_regions
);
 wire stat_valid,stat_sof;wire [31:0] stat_pixel;
 reg [1:0] ends;reg [23:0] raw1,raw2;
 cvp_luma_pack luminance(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_sof(i_sof),.i_rgb(i_rgb),
 .o_valid(stat_valid),.o_sof(stat_sof),.o_pixel(stat_pixel));
 wire [18:0] raw_r={11'd0,i_raw_rgb[23:16]},raw_b={11'd0,i_raw_rgb[7:0]};
 reg [18:0] rr1,gg1,bb1,rr,gg,bb;
 always @(posedge clk)begin
  ends<={ends[0],i_valid&&i_eof};raw1<=i_raw_rgb;raw2<=raw1;
  rr1<=((raw_r<<8)+(raw_r<<6))+((raw_r<<4)+(raw_r<<3));
  gg1<={i_raw_rgb[15:8],8'd0};
  bb1<=((raw_b<<8)+(raw_b<<7))+((raw_b<<6)+(raw_b<<1))+raw_b;
  rr<=rr1;gg<=gg1;bb<=bb1;
 end
 wire [7:0] y=stat_pixel[31:24];wire [4:0] bin=y[7:3];
 localparam LOW_COUNT=(W*H+99)/100,HIGH_COUNT=(W*H*99+99)/100;
 wire [18:0] mx=rr>gg?(rr>bb?rr:bb):(gg>bb?gg:bb);
 wire [18:0] mn=rr<gg?(rr<bb?rr:bb):(gg<bb?gg:bb);
 wire broad_neutral=(mx-mn)*2<=mx && y>32 && y<230 &&
              raw2[23:16]>2 && raw2[15:8]>2 && raw2[7:0]>2 &&
              raw2[23:16]<250 && raw2[15:8]<250 && raw2[7:0]<250;
 // Judge samples AFTER applying the calibrated prior, before any clipping.
 // The strict spread gate rejects beige/brown objects accepted by v26.
 wire safe_neutral=((mx-mn)<<3)<=mx && gg>=19'd16384 && gg<=19'd57344 && mx<19'd60160 && mn>19'd8192;
 wire neutral=SAFE_AWB?safe_neutral:broad_neutral;
 reg [11:0] sx,sy;wire [11:0] px=stat_sof?12'd0:sx,py=stat_sof?12'd0:sy;
 wire [1:0] region={py>=H/2,px>=W/2};
 reg [19:0] region_count[0:3];reg [3:0] regions_snap;
 localparam REGION_MIN=W*H/2000>1?W*H/2000:1;
 wire [2:0] region_total={2'd0,regions_snap[0]}+{2'd0,regions_snap[1]}+{2'd0,regions_snap[2]}+{2'd0,regions_snap[3]};
 wire enough_regions=!SAFE_AWB||region_total>=2;
 reg [31:0] cnt,sum,nc,rs,gs,bs,clip;
 reg [3:0] state;reg [5:0] idx;reg low_set,high_set;
 reg start;reg [31:0] num,den;wire done;wire [31:0] quotient;
 reg [31:0] total,sum_snap,n_snap,r_snap,g_snap,b_snap,cdf;
 /* 亮度直方图: 32bin x 20bit 分布式 RAM(单端口, 异步读/同步写), 替代原
  * 32x20 触发器阵列 + EOF 快照阵列(snap)。读口时间复用: 走查(state==1)用
  * idx, 像素自增用 bin, 消隐清扫用 clr。RAM 无法靠复位清零, 改由消隐期
  * 旋转清扫(hclr)保证每帧帧首全零: 状态 2/3/4(除法等待, ~120 拍)扫完全部
  * 32 bin; 上电后 state==0 且未 arm 时也扫(仿真 TB 需在复位后空等 >=40 拍,
  * 实机由摄像头门控保证上电到首帧远大于 32 拍)。帧尾到走查开始的 1 拍间隙
  * (ends[1] 拍, state 仍为 0)靠 r_armed 屏蔽清扫, 防止清掉走查未读的 bin。 */
 reg [19:0] hist [0:31];
 reg [4:0]  clr;
 reg        r_blank,r_armed;
 wire       walking=(state==4'd1);
 wire [4:0] haddr=walking?idx[4:0]:(stat_valid?bin:clr);
 wire [19:0] hrd=hist[haddr];
 wire hclr=!stat_valid&&!walking&&((state==4'd2)||(state==4'd3)||(state==4'd4)||(r_blank&&!r_armed));
 /* clr 的复位与自增必须同块(单驱动): RAM 写块只读 clr 做地址, 不再赋值。 */
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin clr<=5'd0;r_blank<=1'b1;r_armed<=1'b0;end
  else begin
   if(hclr)clr<=clr+5'd1;
   if(state==4'd4&&done)r_armed<=1'b0;
   if(stat_valid&&stat_sof)r_blank<=1'b0;
   else if(ends[1])begin r_blank<=1'b1;r_armed<=1'b1;end
  end
 end
 always @(posedge clk)begin
  if(stat_valid&&!walking)hist[bin]<=hrd+20'd1;
  else if(hclr)hist[clr]<=20'd0;
 end
 wire [31:0] cnt_next=stat_sof?1:cnt+1'b1,sum_next=(stat_sof?0:sum)+y;
 wire [31:0] n_next=(stat_sof?0:nc)+neutral;
 wire [31:0] rn=(stat_sof?0:rs)+(neutral?raw2[23:16]:0),
             gn=(stat_sof?0:gs)+(neutral?raw2[15:8]:0),
             bn=(stat_sof?0:bs)+(neutral?raw2[7:0]:0);
 cvp_divider div(.clk(clk),.rst_n(rst_n),.start(start),.numerator(num),.denominator(den),.done(done),.quotient(quotient));
 function [10:0] gain_limit;input [31:0] q;begin gain_limit=q<128?128:q>1024?1024:q[10:0];end endfunction
 reg [10:0] candidate_r;
 function [10:0] anchored;
 input [31:0] q;input [10:0] base;input strong;
 reg [31:0] bounded;begin
 bounded=q<(base*3/4)?(base*3/4):q>(base*5/4)?(base*5/4):q;
 anchored=strong?(base+bounded+1)>>1:(base*3+bounded+2)>>2;
 end endfunction
 wire strong_confidence=region_total>=3&&n_snap>=W*H/20;
 integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   cnt<=0;sum<=0;nc<=0;rs<=0;gs<=0;bs<=0;clip<=0;
   total<=0;sum_snap<=0;n_snap<=0;r_snap<=0;g_snap<=0;b_snap<=0;
   cdf<=0;idx<=0;state<=0;low_set<=0;high_set<=0;start<=0;num<=0;den<=1;
   o_done<=0;o_mean<=0;o_black<=0;o_white<=255;o_awb_r<=344;o_awb_g<=256;o_awb_b<=451;
   o_awb_state<=0;o_samples<=0;o_neutral<=0;o_clipped<=0;o_stat_overrun<=0;candidate_r<=344;
   sx<=0;sy<=0;regions_snap<=0;o_awb_regions<=0;o_awb_reason<=0;
   for(k=0;k<4;k=k+1)region_count[k]<=0;
  end else begin
   start<=0;o_done<=0;o_stat_overrun<=0;
   if(stat_valid)begin
    if(px==W-1)begin sx<=0;sy<=py+1'b1;end else begin sx<=px+1'b1;sy<=py;end
    for(k=0;k<4;k=k+1)begin
     if(stat_sof)region_count[k]<=neutral&&region==k?1:0;
     else if(neutral&&region==k)region_count[k]<=region_count[k]+1'b1;
    end
    cnt<=cnt_next;sum<=sum_next;nc<=n_next;rs<=rn;gs<=gn;bs<=bn;
    clip<=(stat_sof?0:clip)+(y>=245);
    if(ends[1])begin
     if(state==0)begin
      total<=cnt_next;sum_snap<=sum_next;n_snap<=n_next;r_snap<=rn;g_snap<=gn;b_snap<=bn;
      for(k=0;k<4;k=k+1)regions_snap[k]<=((stat_sof?0:region_count[k])+(neutral&&region==k))>=REGION_MIN;
      o_samples<=cnt_next;o_neutral<=n_next;o_clipped<=(stat_sof?0:clip)+(y>=245);
      cdf<=0;idx<=0;low_set<=0;high_set<=0;state<=1;
     end else o_stat_overrun<=1;
    end
   end
   case(state)
    1:begin
     cdf<=cdf+hrd;
     if(!low_set && cdf+hrd>=LOW_COUNT)begin o_black<={idx[4:0],3'b000};low_set<=1;end
     if(!high_set && cdf+hrd>=HIGH_COUNT)begin o_white<={idx[4:0],3'b111};high_set<=1;end
     if(idx==31)begin num<=sum_snap;den<=total;start<=1;state<=2;end else idx<=idx+1'b1;
    end
    2:if(done)begin
     o_mean<=quotient[15:8];
     o_awb_regions<=regions_snap;
     if(i_awb_en && total==W*H && n_snap>=(W*H/100>16?W*H/100:16) && r_snap!=0 && b_snap!=0 && enough_regions)begin
      o_awb_reason<=1;
      num<=g_snap;den<=r_snap;start<=1;state<=3;
     end else begin
      o_awb_state<=i_awb_en?2:0;o_awb_reason<=!i_awb_en?0:!enough_regions?3:2;o_done<=1;state<=0;
      if(SAFE_AWB&&!i_awb_en)begin o_awb_r<=344;o_awb_b<=451;end
     end
    end
    3:if(done)begin candidate_r<=SAFE_AWB?anchored(quotient,344,strong_confidence):gain_limit(quotient);num<=g_snap;den<=b_snap;start<=1;state<=4;end
    4:if(done)begin
     o_awb_r<=SAFE_AWB?(o_awb_r*15+candidate_r+8)>>4:(o_awb_r*3+candidate_r+2)>>2;
     o_awb_b<=SAFE_AWB?(o_awb_b*15+anchored(quotient,451,strong_confidence)+8)>>4:(o_awb_b*3+gain_limit(quotient)+2)>>2;
     o_awb_g<=256;o_awb_state<=1;o_done<=1;state<=0;
    end
   endcase
  end
 end
endmodule
