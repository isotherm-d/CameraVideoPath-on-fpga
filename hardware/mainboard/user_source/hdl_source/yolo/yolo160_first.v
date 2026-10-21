// Center640 -> exact RGB160 sampling; streamed W8 convolution + pool2.
// Four source rows bound buffering; no full RGB frame RAM. Frame loss aborts.
`include "yolo160_config.vh"
module yolo160_first #(parameter FRAME_INTERVAL=3,FULL_FRAME=0,
 parameter WFILE="../../../user_source/hdl_source/yolo/model/first8.hex")(
 input clk,rst_n,input i_enable,input i_valid,input [11:0] i_x,i_y,
 input [23:0] i_rgb,input [31:0] i_frame,input [15:0] i_cfg,
 output reg busy,output reg done,output reg aborted,
 output reg we,output reg [12:0] addr,output reg [31:0] data,
 output reg [31:0] frame_id,output reg [15:0] cfg_id
);
 reg [23:0] rows[0:639];reg [191:0] weights[0:8];
 initial $readmemh(WFILE,weights);
 reg [23:0] rq;reg [191:0] wq;
 reg [31:0] poolrow[0:79];reg [31:0] horizontal;
 reg capture;reg [7:0] completed,ox,oy,expect_x,expect_y;reg [2:0] phase;
 reg [3:0] tap;reg [3:0] state;
 reg [9:0] raddr;reg mask_r,first_r,last_r,valid_r;
 reg signed [16:0] product[0:23];reg pf,pl,pv,prepared,prep_first,prep_last;
 reg signed [19:0] sum[0:7];reg sf,sl,sv;
 reg signed [31:0] acc[0:7];reg ended;
 reg [31:0] quant_word,poolq;integer j;
 // Full 1280x720 view maps directly to RGB160. Vertical center-nearest
 // positions alternate by four/five rows: y=2+4*j+floor(j/2).
 reg [7:0] capture_row;reg [11:0] next_source_y;
 wire sample=FULL_FRAME?(i_valid && i_x>=4 && i_x<=1276 && i_x[2:0]==4 && i_y==next_source_y):
             (i_valid && i_x>=322 && i_x<=958 && i_y>=42 && i_y<=678 && i_x[1:0]==2 && i_y[1:0]==2);
 wire first_sample=FULL_FRAME?(i_valid && i_x==4 && i_y==2):(sample && i_x==322 && i_y==42);
 wire capture_start=first_sample && i_enable && !busy && phase==0;
 wire [7:0] cx=FULL_FRAME?(i_x-4)>>3:(i_x-322)>>2;
 wire [7:0] cy=FULL_FRAME?capture_row:(i_y-42)>>2;
 wire [9:0] wa=({8'b0,cy[1:0]}<<7)+({8'b0,cy[1:0]}<<5)+cx;
 wire [1:0] ty=tap<3?0:tap<6?1:2;
 wire [1:0] tx=tap<3?tap[1:0]:tap<6?tap-3:tap-6;
 wire signed [9:0] sy=$signed({2'b0,oy})+$signed({8'b0,ty})-1;
 wire signed [9:0] sx=$signed({2'b0,ox})+$signed({8'b0,tx})-1;
 wire in_range=sx>=0 && sx<160 && sy>=0 && sy<160;
 wire [9:0] read_index=({8'b0,sy[1:0]}<<7)+({8'b0,sy[1:0]}<<5)+sx[7:0];
 function signed [16:0] logic_mul8;
  input [7:0] a;input signed [7:0] b;
  reg signed [16:0] t,p0,p1,p2,p3,p4,p5,p6,p7,s0,s1,s2,s3,q0,q1;
  begin t=b;p0=a[0]?t:0;p1=a[1]?(t<<<1):0;p2=a[2]?(t<<<2):0;p3=a[3]?(t<<<3):0;
   p4=a[4]?(t<<<4):0;p5=a[5]?(t<<<5):0;p6=a[6]?(t<<<6):0;p7=a[7]?(t<<<7):0;
   s0=p0+p1;s1=p2+p3;s2=p4+p5;s3=p6+p7;q0=s0+s1;q1=s2+s3;logic_mul8=q0+q1;end
 endfunction
 function signed [31:0] bias;
  input integer k;
  begin case(k)
   0:bias=`YOLO_C1_B0;1:bias=`YOLO_C1_B1;2:bias=`YOLO_C1_B2;3:bias=`YOLO_C1_B3;
   4:bias=`YOLO_C1_B4;5:bias=`YOLO_C1_B5;6:bias=`YOLO_C1_B6;default:bias=`YOLO_C1_B7;
  endcase end
 endfunction
 function integer shift;
  input integer k;
  begin case(k)
   0:shift=`YOLO_C1_S0;1:shift=`YOLO_C1_S1;2:shift=`YOLO_C1_S2;3:shift=`YOLO_C1_S3;
   4:shift=`YOLO_C1_S4;5:shift=`YOLO_C1_S5;6:shift=`YOLO_C1_S6;default:shift=`YOLO_C1_S7;
  endcase end
 endfunction
 function [3:0] requant;
  input signed [31:0] v;input integer k;reg signed [31:0] q;integer s;
  begin s=shift(k);q=(v+bias(k)+(s?32'sd1<<<(s-1):0))>>>s;
   requant=q<0?0:q>15?15:q[3:0];end
 endfunction
 always @(posedge clk) begin
  if((capture && sample) || capture_start)rows[capture_start?10'd0:wa]<=i_rgb;
  rq<=rows[read_index];wq<=weights[tap<9?tap:0];
  poolq<=poolrow[ox>>1];
  if(state==5 && !oy[0])poolrow[ox>>1]<=quant_word;
 end
 genvar g;
 generate for(g=0;g<24;g=g+1)begin:M
  wire [7:0] rgb_byte=(g%3==0)?rq[23:16]:(g%3==1)?rq[15:8]:rq[7:0];
  wire signed [7:0] wt=wq[g*8+:8];
  reg [7:0] aq;reg signed [7:0] wreg;
  always @(posedge clk)begin aq<=mask_r?0:rgb_byte;wreg<=wt;end
  if(g<16)begin:D
   always @(posedge clk)product[g]<=$signed({1'b0,aq})*wreg;
  end else begin:L
   always @(posedge clk)product[g]<=logic_mul8(aq,wreg);
  end
 end endgenerate
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid_r<=0;pv<=0;sv<=0;pf<=0;pl<=0;sf<=0;sl<=0;mask_r<=1;first_r<=0;last_r<=0;ended<=0;prepared<=0;prep_first<=0;prep_last<=0;
   for(j=0;j<8;j=j+1)begin acc[j]<=0;sum[j]<=0;end
  end else begin
   valid_r<=state==2;mask_r<=!in_range;first_r<=tap==0;last_r<=tap==8;
   prepared<=valid_r;prep_first<=first_r;prep_last<=last_r;
   pv<=prepared;pf<=prep_first;pl<=prep_last;sv<=pv;sf<=pf;sl<=pl;ended<=0;
   for(j=0;j<8;j=j+1)begin
    sum[j]<=$signed(product[j*3])+$signed(product[j*3+1])+$signed(product[j*3+2]);
    if(sv)acc[j]<=sf?$signed(sum[j]):acc[j]+$signed(sum[j]);
   end
   if(sv && sl)ended<=1;
  end
 end
 reg [31:0] horizontal_max;reg [31:0] vertical_max;
 always @* begin
  horizontal_max=0;vertical_max=0;
  for(integer k=0;k<8;k=k+1)begin
   horizontal_max[k*4+:4]=horizontal[k*4+:4]>quant_word[k*4+:4]?horizontal[k*4+:4]:quant_word[k*4+:4];
   vertical_max[k*4+:4]=poolq[k*4+:4]>quant_word[k*4+:4]?poolq[k*4+:4]:quant_word[k*4+:4];
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;capture<=0;done<=0;aborted<=0;we<=0;addr<=0;data<=0;
   completed<=0;ox<=0;oy<=0;expect_x<=0;expect_y<=0;tap<=0;state<=0;frame_id<=0;cfg_id<=0;phase<=0;horizontal<=0;quant_word<=0;capture_row<=0;next_source_y<=2;
  end else begin
   done<=0;aborted<=0;we<=0;
   if(first_sample)begin
    if(phase==FRAME_INTERVAL-1)phase<=0;else phase<=phase+1'b1;
    if(i_enable && !busy && phase==0)begin
     busy<=1;capture<=1;completed<=0;ox<=0;oy<=0;expect_x<=1;expect_y<=0;tap<=0;state<=1;frame_id<=i_frame;cfg_id<=i_cfg;
     capture_row<=0;next_source_y<=2;
    end
   end
   if(capture && sample && cx==159)begin
    completed<=cy+1'b1;if(cy==159)capture<=0;
    if(FULL_FRAME)begin capture_row<=capture_row+1'b1;next_source_y<=next_source_y+4+capture_row[0];end
   end
   if(capture && sample)begin
    if(cx==159)begin expect_x<=0;expect_y<=expect_y+1'b1;end else expect_x<=expect_x+1'b1;
   end
   if(busy)case(state)
    1:if(completed>oy+1 || (oy==159 && completed==160))begin state<=2;tap<=0;end
    2:if(tap==8)begin state<=3;end else tap<=tap+1'b1;
    3:if(ended)begin
     for(j=0;j<8;j=j+1)quant_word[j*4+:4]<=requant(acc[j],j);
     state<=4;
    end
    4:begin
     if(!ox[0])begin horizontal<=quant_word;state<=6;end
     else begin quant_word<=horizontal_max;state<=5;end
    end
    5:begin
     if(oy[0])begin we<=1;addr<=({6'b0,oy[7:1]}<<6)+({6'b0,oy[7:1]}<<4)+{6'b0,ox[7:1]};data<=vertical_max;end
     state<=6;
    end
    6:begin
     if(ox==159)begin
      ox<=0;
      if(oy==159)begin busy<=0;done<=1;state<=0;end
      else begin oy<=oy+1'b1;state<=1;end
     end else begin ox<=ox+1'b1;tap<=0;state<=2;end
    end
    default:;
   endcase
   // Four-row ring must never overwrite the oldest row still being used.
   if(busy && (i_cfg!=cfg_id ||
      (capture && i_frame!=frame_id && !first_sample) ||
      (capture && sample && (cx!=expect_x || cy!=expect_y)) ||
      (FULL_FRAME && capture && i_valid && i_y>next_source_y) ||
      (capture && sample && cx==0 && cy>=oy+3)))begin
    busy<=0;capture<=0;state<=0;aborted<=1;
   end
  end
 end
endmodule
