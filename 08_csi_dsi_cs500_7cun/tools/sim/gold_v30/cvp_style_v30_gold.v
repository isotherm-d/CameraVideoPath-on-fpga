module cvp_style_v30_gold #(parameter W=1280,H=720)(
 input clk,rst_n,i_valid,input [23:0] i_rgb,input i_sof,
 input [31:0] i_frame_id,input [15:0] i_cfg_id,input [7:0] i_mode,
 input i_osd_en,i_ae_en,input [1:0] i_wb_mode,
 input [7:0] i_binary_th,input [10:0] i_edge_low,i_edge_high,
 output reg o_osd_en,o_ae_en,output reg [1:0] o_wb_mode,
 output reg o_valid,output reg [23:0] o_rgb,output reg o_sof,o_eol,o_eof,
 output reg [11:0] o_x,o_y,output reg [31:0] o_frame_id,
 output reg [15:0] o_cfg_id,output reg [7:0] o_mode,output o_overflow
);
 wire wv,ws,we,wl,overflow;wire [11:0] wx,wy;
 wire [31:0] a,b,c,d,e,f,g,h,j;
 wire luminance_valid,luminance_sof;wire [31:0] luminance_pixel;
 cvp_luma_pack pre(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_sof(i_sof),.i_rgb(i_rgb),.o_valid(luminance_valid),.o_sof(luminance_sof),.o_pixel(luminance_pixel));
 cvp_window3x3 #(.W(W),.H(H),.DW(32)) win(.clk(clk),.rst_n(rst_n),
 .i_valid(luminance_valid),.i_data(luminance_pixel),.i_sof(luminance_sof),.o_valid(wv),.o_sof(ws),.o_eol(wl),.o_eof(we),
 .o_x(wx),.o_y(wy),.p00(a),.p01(b),.p02(c),.p10(d),.p11(e),.p12(f),
 .p20(g),.p21(h),.p22(j),.o_overflow(overflow));
 /* A3: 元数据 FIFO(16 深, 被综合成 2 块 ERAM20K)改为单 pend 寄存器。
  * 帧原子字段只需跨过窗口流水的 2~3 拍, 帧间消隐远大于前帧排空深度,
  * 队列永不积压; pend_v 复现原 FIFO 的满/空溢出检查语义。 */
 reg [89:0] pend;reg pend_v;
 wire meta_sof=i_valid&&i_sof;
 assign o_overflow=overflow||(meta_sof&&pend_v)||((wv&&ws)&&!pend_v);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin pend<=0;pend_v<=1'b0;end
  else begin
   if(wv&&ws)pend_v<=1'b0;
   if(meta_sof)begin pend<={i_osd_en,i_ae_en,i_wb_mode,i_frame_id,i_cfg_id,i_mode,i_binary_th,i_edge_low,i_edge_high};pend_v<=1'b1;end
  end
 end
 reg [89:0] active;
 wire [89:0] current=ws?pend:active;
 wire medv,medfs,sobv,sobfs;wire [23:0] medrgb,sobrgb;wire [10:0] magnitude;
 cvp_fx_median_v30_gold med(.i_clk(clk),.i_rst_n(rst_n),.i_valid(wv),.i_frame_start(ws),
 .i_p00(a[23:0]),.i_p01(b[23:0]),.i_p02(c[23:0]),.i_p10(d[23:0]),.i_p11(e[23:0]),.i_p12(f[23:0]),
 .i_p20(g[23:0]),.i_p21(h[23:0]),.i_p22(j[23:0]),.o_valid(medv),.o_frame_start(medfs),.o_rgb(medrgb));
 cvp_fx_sobel #(.IMG_W(W),.POST_FILTER(0)) sob(.i_clk(clk),.i_rst_n(rst_n),.i_valid(wv),
 .i_frame_start(ws),.i_th_low(current[21:11]),.i_th_high(current[10:0]),.i_p00(a),.i_p01(b),.i_p02(c),.i_p10(d),.i_p11(e),.i_p12(f),
 .i_p20(g),.i_p21(h),.i_p22(j),.o_valid(sobv),.o_frame_start(sobfs),.o_rgb(sobrgb),.o_mag(magnitude));
 function [7:0] luma;input [23:0] p;reg [17:0] s;begin
 s=p[23:16]*18'd77+p[15:8]*18'd150+p[7:0]*18'd29+18'd128;luma=s[15:8];end endfunction
 function [7:0] sat;input [17:0] s;begin sat=|s[17:16]?8'd255:s[15:8];end endfunction
 reg [3:0] vp,sp,lp,ep;reg edge_delay;
 reg [23:0] bypass[0:3],sepia[0:3],xy[0:3];
 reg [3:0] fp[0:3];
 reg [63:0] mp[0:3];reg [7:0] yp[0:3];
 wire [17:0] r={10'd0,e[23:16]},green={10'd0,e[15:8]},blue={10'd0,e[7:0]};
 // Constant shifts/adds instead of nine general DSP multipliers.
 reg [17:0] cr1,cg1,cb1,cr2,cg2,cb2,cr3,cg3,cb3;
 wire [17:0] sr=cr1+cg1+cb1+18'd128,sg=cr2+cg2+cb2+18'd128,sb=cr3+cg3+cb3+18'd128;
 always @(posedge clk)begin
  cr1<=((r<<6)+(r<<5))+((r<<2)+r);cg1<=((green<<7)+(green<<6))+((green<<2)+green);cb1<=(blue<<5)+(blue<<4);
  cr2<=((r<<6)+(r<<4))+((r<<3)+r);cg2<=((green<<7)+(green<<5))+(green<<4);cb2<=((blue<<5)+(blue<<3))+((blue<<1)+blue);
  cr3<=((r<<6)+(r<<2))+(r<<1);cg3<=((green<<7)+(green<<3))+green;cb3<=(blue<<5)+(blue<<1);
 end
 wire [23:0] quantized={{medrgb[23:21],medrgb[23:21],medrgb[23:22]},
                       {medrgb[15:13],medrgb[15:13],medrgb[15:14]},
                       {medrgb[7:5],medrgb[7:5],medrgb[7:6]}};
 integer k;
 /* B1: 有效/帧标志保留异步复位; 纯数据延迟链与输出数据摘除复位——
  * 首帧首个有效像素到达前各级延迟链刚好随流水写满, 摘复位不改变
  * 有效期内行为, 只为统一 FF 控制集、提升 slice 打包率。 */
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   vp<=0;sp<=0;lp<=0;ep<=0;
   o_valid<=0;o_sof<=0;o_eol<=0;o_eof<=0;
  end else begin
   vp<={vp[2:0],wv};sp<={sp[2:0],ws};lp<={lp[2:0],wl};ep<={ep[2:0],we};
   o_valid<=vp[3];o_sof<=vp[3]&&sp[3];o_eol<=vp[3]&&lp[3];o_eof<=vp[3]&&ep[3];
  end
 end
 always @(posedge clk)begin
  if(wv&&ws)active<=pend;
  edge_delay<=|sobrgb;
  bypass[0]<=e;sepia[1]<={sat(sr),sat(sg),sat(sb)};xy[0]<={wx,wy};mp[0]<=current[85:22];fp[0]<=current[89:86];yp[0]<=e[31:24];
  for(k=1;k<4;k=k+1)begin fp[k]<=fp[k-1];bypass[k]<=bypass[k-1];if(k>1)sepia[k]<=sepia[k-1];xy[k]<=xy[k-1];mp[k]<=mp[k-1];yp[k]<=yp[k-1];end
  {o_osd_en,o_ae_en,o_wb_mode}<=fp[3];
  o_x<=xy[3][23:12];o_y<=xy[3][11:0];o_frame_id<=mp[3][63:32];o_cfg_id<=mp[3][31:16];o_mode<=mp[3][15:8];
  case(mp[3][15:8])
   1:o_rgb<={3{yp[3]}};
   2:o_rgb<=yp[3]>=mp[3][7:0]?24'hffffff:24'd0;
   3:o_rgb<=edge_delay?24'hffffff:24'd0;
   4:o_rgb<=edge_delay?24'd0:quantized;
   5:o_rgb<=edge_delay?24'd0:24'hffffff;
   6:o_rgb<=sepia[3];
   default:o_rgb<=bypass[3];
  endcase
 end
endmodule
