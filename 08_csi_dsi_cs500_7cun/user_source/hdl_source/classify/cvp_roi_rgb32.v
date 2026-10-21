// One complete RGB square per detector snapshot, round-robin. Center nearest
// resize; all variable multiplication is confined to the blanking preparation.
// Dual synchronous patch banks decouple the camera from the serial CNN loader.
module cvp_roi_rgb32 #(parameter N=5,W=1280,H=720,MARGIN=16)(
 input clk,rst_n, input i_snapshot, input [N*48-1:0] i_boxes,
 input [N*32-1:0] i_tokens,input [31:0] i_detect_frame,input [15:0] i_box_cfg,
 input i_valid,i_sof,input [11:0] i_x,i_y,input [23:0] i_rgb,
 input [31:0] i_frame,input [15:0] i_cfg,
 input i_busy,i_done,input [2:0] i_pred,
 output wire o_img_we,output wire [11:0] o_img_addr,output wire [7:0] o_img_data,
 output wire o_start,output reg o_result,output reg [31:0] o_token,o_capture_frame,
 output reg [15:0] o_cfg,output reg [2:0] o_class,output reg [47:0] o_bbox,
 output reg [31:0] o_dropped,o_aborted
);
 (* ram_style="bram" *) reg [23:0] bank0[0:1023],bank1[0:1023];
 reg [23:0] rd0,rd1;
 reg [1:0] ready;reg cap,cap_bank;reg [4:0] cx,cy;
 reg [31:0] bt[0:1],bf[0:1];reg [15:0] bc[0:1];reg [47:0] bb[0:1];
 reg [11:0] sx[0:31],sy[0:31];
 reg [2:0] prep;reg armed;reg [3:0] rr,sel,scan;reg [5:0] j;integer ki;
 reg [47:0] chosen;reg [31:0] chosen_token,df;reg [15:0] cfg;
 reg [11:0] ex0,ey0,ex1,ey1,side,ox,oy;
 reg [17:0] sample_acc;
 reg [2:0] ls;reg lb;reg [11:0] count;
 wire [23:0] rd=lb?rd1:rd0;
 localparam L_IDLE=0,L_READ=1,L_WRITE=2,L_START=3,L_RUN=4;
 wire free0=!ready[0] && !(ls!=L_IDLE && ls!=L_RUN && !lb);
 wire free1=!ready[1] && !(ls!=L_IDLE && ls!=L_RUN && lb);
 wire launch=i_valid && i_sof && armed && !cap && cfg==i_cfg && i_frame-df>0 && i_frame-df<=2 && (free0||free1);
 wire hit=i_valid && ((launch && i_x==sx[0] && i_y==sy[0]) ||
  (cap && !i_sof && i_cfg==bc[cap_bank] && i_frame==bf[cap_bank] && i_x==sx[cx] && i_y==sy[cy]));
 wire write_bank=launch?!free0:cap_bank;
 wire [9:0] wa=launch?10'd0:{cy,cx};
 wire [47:0] candidate=i_boxes[sel*48+:48];
 always @(posedge clk)begin
  if(hit && !write_bank)bank0[wa]<=i_rgb;
  if(hit && write_bank)bank1[wa]<=i_rgb;
  rd0<=bank0[count[9:0]];rd1<=bank1[count[9:0]];
 end
 assign o_img_we=ls==L_WRITE;
 assign o_img_addr=count;
 assign o_img_data=count[11:10]==0?rd[23:16]:count[11:10]==1?rd[15:8]:rd[7:0];
 assign o_start=ls==L_START;
 integer xsum,ysum,span;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   ready<=0;cap<=0;cap_bank<=0;cx<=0;cy<=0;prep<=0;armed<=0;
   rr<=0;sel<=0;scan<=0;j<=0;chosen<=0;chosen_token<=0;df<=0;cfg<=0;
   ex0<=0;ey0<=0;ex1<=0;ey1<=0;side<=32;ox<=0;oy<=0;sample_acc<=0;
   ls<=L_IDLE;lb<=0;count<=0;o_result<=0;o_token<=0;o_capture_frame<=0;
   o_cfg<=0;o_class<=0;o_bbox<=0;o_dropped<=0;o_aborted<=0;
   for(ki=0;ki<2;ki=ki+1)begin bt[ki]<=0;bf[ki]<=0;bc[ki]<=0;bb[ki]<=0;end
  end else begin
   o_result<=0;
   // Preparation only changes sample coordinates outside an active capture.
   // Launch has priority over a coincident snapshot. Its prepared coordinates
   // must remain immutable for the entire patch; the new snapshot is dropped.
   if(i_snapshot && !cap && !launch)begin prep<=1;armed<=0;sel<=rr;scan<=0;end
   else case(prep)
    1:begin
     if(candidate[47:36]<candidate[23:12] && candidate[35:24]<candidate[11:0] && candidate[23:12]<W && candidate[11:0]<H)begin
      chosen<=candidate;
      chosen_token<=i_tokens[sel*32+:32];df<=i_detect_frame;cfg<=i_box_cfg;
      ex0<=candidate[47:36]>MARGIN?candidate[47:36]-MARGIN:0;
      ey0<=candidate[35:24]>MARGIN?candidate[35:24]-MARGIN:0;
      ex1<=candidate[23:12]>=W-MARGIN?W-1:candidate[23:12]+MARGIN;
      ey1<=candidate[11:0]>=H-MARGIN?H-1:candidate[11:0]+MARGIN;
      rr<=sel==N-1?0:sel+1;prep<=2;
     end else if(scan==N-1)prep<=0;
     else begin scan<=scan+1;sel<=sel==N-1?0:sel+1;end
    end
    2:begin
     span=(ex1-ex0+1)>(ey1-ey0+1)?(ex1-ex0+1):(ey1-ey0+1);
     if(span<32)span=32;
     if(span>W || span>H)begin prep<=0;o_dropped<=o_dropped+1'b1;end
     else begin
      side<=span;sample_acc<=span;
      xsum=ex0+ex1+1-span;ysum=ey0+ey1+1-span;
      if(xsum<0)ox<=0;else if((xsum>>1)>W-span)ox<=W-span;else ox<=xsum>>1;
      if(ysum<0)oy<=0;else if((ysum>>1)>H-span)oy<=H-span;else oy<=ysum>>1;
      j<=0;prep<=3;
     end
    end
    3:begin
     sx[j]<=ox+sample_acc[17:6];sy[j]<=oy+sample_acc[17:6];
     sample_acc<=sample_acc+{side,1'b0};
     if(j==31)begin prep<=0;armed<=1;end else j<=j+1;
    end
    default:;
   endcase
   if(i_valid && i_sof)begin
    if(cap)begin cap<=0;o_aborted<=o_aborted+1'b1;end
    if(armed)begin
     armed<=0;
     if(launch)begin
      if(free0)begin
       cap_bank<=0;bt[0]<=chosen_token;bf[0]<=i_frame;bc[0]<=i_cfg;bb[0]<=chosen;
      end else begin cap_bank<=1;bt[1]<=chosen_token;bf[1]<=i_frame;bc[1]<=i_cfg;bb[1]<=chosen;end
      cap<=1;cx<=0;cy<=0;
     end else o_dropped<=o_dropped+1'b1;
    end
   end
   if(hit)begin
    if(launch)cx<=1;
    else if(cx==31)begin cx<=0;if(cy==31)begin ready[cap_bank]<=1;cap<=0;end else cy<=cy+1'b1;end
    else cx<=cx+1'b1;
   end
   case(ls)
    L_IDLE:if(!i_busy && ready!=0)begin
     lb<=ready[0]?0:1;count<=0;ls<=L_READ;
     o_token<=ready[0]?bt[0]:bt[1];o_capture_frame<=ready[0]?bf[0]:bf[1];
     o_cfg<=ready[0]?bc[0]:bc[1];o_bbox<=ready[0]?bb[0]:bb[1];
    end
    L_READ:ls<=L_WRITE;
    L_WRITE:if(count==3071)begin ready[lb]<=0;ls<=L_START;end
     else begin count<=count+1'b1;ls<=L_READ;end
    L_START:ls<=L_RUN;
    L_RUN:if(i_done)begin o_result<=1;o_class<=i_pred;ls<=L_IDLE;end
    default:ls<=L_IDLE;
   endcase
  end
 end
endmodule
