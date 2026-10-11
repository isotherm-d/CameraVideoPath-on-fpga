// V27 grayscale-only contour path. Four bounded line windows, no frame RAM.
// Metadata is frame-atomic; normal camera frame blanking must exceed 4*W clocks.
module cvp_contour #(parameter W=1280,H=720)(
 input clk,rst_n,i_valid,input [127:0] i_pixel,
 input [10:0] i_low,i_high,input [1:0] i_width,
 output reg o_valid,output reg [127:0] o_pixel,output o_overflow
);
 wire lv,ls;wire [31:0] luma;
 cvp_luma_pack lp(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_sof(i_pixel[104]),.i_rgb(i_pixel[23:0]),.o_valid(lv),.o_sof(ls),.o_pixel(luma));
 wire av,as,ae,al,af;wire [11:0] ax,ay;wire [7:0] a,b,c,d,e,f,g,h,j;
 cvp_window3x3 #(.W(W),.H(H),.DW(8)) smooth_window(.clk(clk),.rst_n(rst_n),.i_valid(lv),.i_sof(ls),.i_data(luma[31:24]),
 .o_valid(av),.o_sof(as),.o_eol(al),.o_eof(ae),.o_x(ax),.o_y(ay),.p00(a),.p01(b),.p02(c),.p10(d),.p11(e),.p12(f),.p20(g),.p21(h),.p22(j),.o_overflow(af));
 reg [9:0] row0,row1,row2;reg [11:0] weighted;reg [7:0] smooth;reg [2:0] vp,sp;
 always @(posedge clk)begin
  row0<={2'd0,a}+{1'd0,b,1'b0}+{2'd0,c};row1<={2'd0,d}+{1'd0,e,1'b0}+{2'd0,f};row2<={2'd0,g}+{1'd0,h,1'b0}+{2'd0,j};
  weighted<={2'd0,row0}+{1'd0,row1,1'b0}+{2'd0,row2}+12'd8;smooth<=weighted[11:4];
 end
 always @(posedge clk or negedge rst_n)if(!rst_n)begin vp<=0;sp<=0;end else begin vp<={vp[1:0],av};sp<={sp[1:0],as};end
 wire bv,bs,bf;wire [7:0] ba,bb,bc,bd,be,bf0,bg,bh,bj;
 cvp_window3x3 #(.W(W),.H(H),.DW(8)) gradient_window(.clk(clk),.rst_n(rst_n),.i_valid(vp[2]),.i_sof(sp[2]),.i_data(smooth),
 .o_valid(bv),.o_sof(bs),.o_eol(),.o_eof(),.o_x(),.o_y(),.p00(ba),.p01(bb),.p02(bc),.p10(bd),.p11(be),.p12(bf0),.p20(bg),.p21(bh),.p22(bj),.o_overflow(bf));
 /* A3: 两个元数据 FIFO(2 深)改为单 pend 寄存器 + pend_v 满/空检查,
  * 帧原子字段只需跨过 4 级窗口流水的固定延迟, 队列无积压可能。 */
 reg [89:0] pend;reg pend_v;reg [89:0] active;
 wire meta_sof=i_valid&&i_pixel[104];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin pend<=0;pend_v<=1'b0;end
  else begin
   if(bv&&bs)pend_v<=1'b0;
   if(meta_sof)begin pend<={i_pixel[111:48],i_width,i_low,i_high,2'd0};pend_v<=1'b1;end
  end
 end
 wire [89:0] current=bs?pend:active;
 wire gv,gs;wire [10:0] mag;wire [23:0] unused;
 cvp_fx_sobel gradient(.i_clk(clk),.i_rst_n(rst_n),.i_valid(bv),.i_frame_start(bs),.i_th_low(current[23:13]),.i_th_high(current[12:2]),
 .i_p00({ba,24'd0}),.i_p01({bb,24'd0}),.i_p02({bc,24'd0}),.i_p10({bd,24'd0}),.i_p11({be,24'd0}),.i_p12({bf0,24'd0}),
 .i_p20({bg,24'd0}),.i_p21({bh,24'd0}),.i_p22({bj,24'd0}),.o_valid(gv),.o_frame_start(gs),.o_rgb(unused),.o_mag(mag));
 reg [89:0] mp[0:2];integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;for(k=0;k<3;k=k+1)mp[k]<=0;end
  else begin if(bv&&bs)active<=pend;mp[0]<=current;mp[1]<=mp[0];mp[2]<=mp[1];end
 end
 wire [1:0] category={mag>=mp[2][12:2],mag>=mp[2][23:13]};
 wire cv,cs,cf;wire [1:0] ca,cb,cc,cd,ce,cf0,cg,ch,cj;
 cvp_window3x3 #(.W(W),.H(H),.DW(2)) connect_window(.clk(clk),.rst_n(rst_n),.i_valid(gv),.i_sof(gs),.i_data(category),
 .o_valid(cv),.o_sof(cs),.o_eol(),.o_eof(),.o_x(),.o_y(),.p00(ca),.p01(cb),.p02(cc),.p10(cd),.p11(ce),.p12(cf0),.p20(cg),.p21(ch),.p22(cj),.o_overflow(cf));
 wire nearby_strong=ca[1]|cb[1]|cc[1]|cd[1]|cf0[1]|cg[1]|ch[1]|cj[1];
 wire nearby_candidate=ca[0]|cb[0]|cc[0]|cd[0]|cf0[0]|cg[0]|ch[0]|cj[0];
 wire [1:0] connected=ce[1]&&nearby_candidate?2'd2:ce[0]&&nearby_strong?2'd1:2'd0;
 wire dv,ds,de,dl,df;wire [11:0] dx,dy;wire [1:0] da,db,dc,dd,dd0,df0,dg,dh,dj;
 cvp_window3x3 #(.W(W),.H(H),.DW(2)) width_window(.clk(clk),.rst_n(rst_n),.i_valid(cv),.i_sof(cs),.i_data(connected),
 .o_valid(dv),.o_sof(ds),.o_eol(dl),.o_eof(de),.o_x(dx),.o_y(dy),.p00(da),.p01(db),.p02(dc),.p10(dd),.p11(dd0),.p12(df0),.p20(dg),.p21(dh),.p22(dj),.o_overflow(df));
 reg [61:0] fpend;reg fpend_v;reg [61:0] final_active;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin fpend<=0;fpend_v<=1'b0;end
  else begin
   if(dv&&ds)fpend_v<=1'b0;
   if(meta_sof)begin fpend<={i_pixel[111:108],i_pixel[79:48],i_pixel[95:80],i_pixel[103:96],i_width};fpend_v<=1'b1;end
  end
 end
 wire [61:0] frame=ds?fpend:final_active;
 wire strong=da==2||db==2||dc==2||dd==2||dd0==2||df0==2||dg==2||dh==2||dj==2;
 wire weak=|da||(|db)||(|dc)||(|dd)||(|dd0)||(|df0)||(|dg)||(|dh)||(|dj);
 wire [1:0] selected=frame[1:0]==2?(strong?2'd2:weak?2'd1:2'd0):dd0;
 wire [7:0] shade=frame[9:2]==5?(selected==2?8'd0:selected==1?8'd96:8'd255):(selected!=0?8'd255:8'd0);
 // Register the complete token before branch selection/OSD glyph decoding.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin o_valid<=0;o_pixel<=0;end
  else begin o_valid<=dv;o_pixel<={16'd0,frame[61:58],i_pixel[107],de,dl,ds,frame[9:2],frame[25:10],frame[57:26],dy,dx,{3{shade}}};end
 end
 assign o_overflow=af||bf||cf||df||(meta_sof&&(pend_v||fpend_v))||((bv&&bs)&&!pend_v)||((dv&&ds)&&!fpend_v);
 always @(posedge clk or negedge rst_n)if(!rst_n)final_active<=0;else if(dv&&ds)final_active<=fpend;
endmodule
