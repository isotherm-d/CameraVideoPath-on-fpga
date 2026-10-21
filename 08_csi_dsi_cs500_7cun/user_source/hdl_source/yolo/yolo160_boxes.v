// LUT sigmoid, fixed-point YOLO decode, bounded top20 and greedy NMS.
// Five-class head: each anchor emits xywh, objectness, BAS/EOS/LYM/MON/NEU.
// Full 1280x720 coordinates, class-agnostic NMS prevents duplicate cell types.
`include "yolo160_threshold.vh"
module yolo160_boxes #(parameter SFILE="../../../user_source/hdl_source/yolo/model/sigmoid.hex")(
 input clk,rst_n,input i_start,i_abort,input [31:0] i_frame,input [15:0] i_cfg,
 input i_valid,input [3:0] i_x,i_y,input [4:0] i_channel,input signed [15:0] i_logit,input i_done,
 output reg busy,output reg commit,output reg [239:0] boxes,
 output reg [14:0] classes,output reg [79:0] scores,
 output reg [31:0] frame_id,output reg [15:0] cfg_id,output reg overrun
);
 reg [7:0] sigmoid[0:255];initial $readmemh(SFILE,sigmoid);
 wire signed [16:0] lookup=$signed(i_logit)>>>4;
 wire [7:0] si=lookup< -128?0:lookup>127?255:lookup+128;
 wire [7:0] probability=sigmoid[si];
 reg [7:0] qx,qy,qw,qh,qo;
 wire [1:0] input_anchor=i_channel>=20?2:i_channel>=10?1:0;
 wire [3:0] field=i_channel>=20?i_channel-20:i_channel>=10?i_channel-10:i_channel;
 reg [7:0] class_probability;reg [2:0] class_index,new_class;
 wire [7:0] peak_probability=probability>class_probability?probability:class_probability;
 wire [2:0] peak_class=probability>class_probability?3'd4:class_index;
 reg [47:0] cand_box[0:19];reg [15:0] cand_score[0:19];
 reg [2:0] cand_class[0:19];reg [14:0] working_classes;reg [79:0] working_scores;
 wire [8:0] grid_order=({5'b0,i_y}<<3)+({5'b0,i_y}<<1)+{5'b0,i_x};
 reg [8:0] cand_order[0:19];reg [8:0] new_order,best_order,min_order;
 reg [4:0] count,scan,best_index,min_index;
 reg [15:0] best_score,min_score,new_score;
 reg [47:0] new_box,ref_box;reg [239:0] working;reg [2:0] kept;
 reg [5:0] state;reg finish_pending;
 reg [1:0] anchor;
 reg signed [17:0] center_x,center_y;
 reg [15:0] square_w,square_h;
 reg [23:0] width_product,height_product;
 reg signed [18:0] left,right,top,bottom;
 reg [10:0] mul_a,mul_b,inter_w,inter_h;
 reg [19:0] mul_q,ref_area,cand_area,intersection;
 reg [20:0] union_area;
 wire [11:0] bx0=cand_box[scan][47:36],by0=cand_box[scan][35:24],bx1=cand_box[scan][23:12],by1=cand_box[scan][11:0];
 wire [11:0] rx0=ref_box[47:36],ry0=ref_box[35:24],rx1=ref_box[23:12],ry1=ref_box[11:0];
 wire [11:0] ix0=bx0>rx0?bx0:rx0,iy0=by0>ry0?by0:ry0,ix1=bx1<rx1?bx1:rx1,iy1=by1<ry1?by1:ry1;
 wire [28:0] u103=({8'b0,union_area}<<6)+({8'b0,union_area}<<5)+({8'b0,union_area}<<2)+({8'b0,union_area}<<1)+union_area;
 function [11:0] clip_x;
  input signed [18:0] v;reg signed [18:0] q;
  begin q=v>>>5;clip_x=q<0?0:q>1279?1279:q[11:0];end
 endfunction
 function [11:0] clip_y;
  input signed [18:0] v;reg signed [22:0] wide,q;
  begin wide=v;q=(wide+(wide<<<3))>>>9;clip_y=q<0?0:q>719?719:q[11:0];end
 endfunction
 always @(posedge clk)mul_q<=mul_a*mul_b;
 integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   busy<=0;commit<=0;boxes<={240{1'b1}};frame_id<=0;cfg_id<=0;overrun<=0;
   classes<={5{3'd5}};scores<=0;working_classes<={5{3'd5}};working_scores<=0;
   class_probability<=0;class_index<=0;new_class<=0;
   state<=0;count<=0;scan<=0;best_index<=0;min_index<=0;best_score<=0;min_score<=0;new_score<=0;
   new_box<=0;ref_box<=0;working<={240{1'b1}};kept<=0;finish_pending<=0;
   qx<=0;qy<=0;qw<=0;qh<=0;qo<=0;anchor<=0;center_x<=0;center_y<=0;square_w<=0;square_h<=0;
   width_product<=0;height_product<=0;left<=0;right<=0;top<=0;bottom<=0;
   mul_a<=0;mul_b<=0;inter_w<=0;inter_h<=0;ref_area<=0;cand_area<=0;intersection<=0;union_area<=0;
   new_order<=0;best_order<=511;min_order<=0;
   for(k=0;k<20;k=k+1)begin cand_box[k]<=0;cand_score[k]<=0;cand_order[k]<=0;cand_class[k]<=0;end
  end else begin
   commit<=0;
   if(i_done)finish_pending<=1;
   if(i_valid)begin
    case(field)
     0:qx<=probability;1:qy<=probability;2:qw<=probability;3:qh<=probability;4:qo<=probability;
     5:begin class_probability<=probability;class_index<=0;end
     6,7,8:if(probability>class_probability)begin class_probability<=probability;class_index<=field-5;end
     9:begin
      if(state!=0)overrun<=1;
      else begin
       anchor<=input_anchor;
`ifdef YOLO_OBJECTNESS_ONLY
       // BCCD supervises detection without five-type labels. Keep the learned
       // objectness gate independent of the five-logit type argmax.
       new_score<={qo,8'b0}-{8'b0,qo};
`else
       new_score<=qo*peak_probability;
`endif
       new_class<=peak_class;
       new_order<=(grid_order<<1)+grid_order+input_anchor;
       center_x<=$signed({1'b0,i_x,8'b0})*16+($signed({1'b0,qx})*2-128)*16;
       center_y<=$signed({1'b0,i_y,8'b0})*16+($signed({1'b0,qy})*2-128)*16;
       square_w<=qw*qw;square_h<=qh*qh;state<=1;
      end
     end
    endcase
   end
   case(state)
    0:if(finish_pending)begin finish_pending<=0;working<={240{1'b1}};working_classes<={5{3'd5}};working_scores<=0;kept<=0;scan<=0;best_score<=0;best_index<=0;best_order<=511;state<=20;end
    1:begin
     // Multiply by the three fixed anchor dimensions using shifts/adds.
     case(anchor)
      0:begin width_product<=({8'b0,square_w}<<4)+({8'b0,square_w}<<2);height_product<=({8'b0,square_h}<<4)+({8'b0,square_h}<<3);end
      1:begin width_product<=({8'b0,square_w}<<5)+({8'b0,square_w}<<3);height_product<=({8'b0,square_h}<<5)+({8'b0,square_h}<<4);end
      default:begin width_product<=({8'b0,square_w}<<6)+({8'b0,square_w}<<4);height_product<=({8'b0,square_h}<<6)+({8'b0,square_h}<<4)+({8'b0,square_h}<<3);end
     endcase
     state<=2;
    end
    2:begin
     left<=$signed(center_x)-$signed({2'b0,width_product[23:7]});right<=$signed(center_x)+$signed({2'b0,width_product[23:7]});
     top<=$signed(center_y)-$signed({2'b0,height_product[23:7]});bottom<=$signed(center_y)+$signed({2'b0,height_product[23:7]});state<=3;
    end
    3:begin
     new_box<={clip_x(left),clip_y(top),clip_x(right),clip_y(bottom)};
     if(new_score<`YOLO_SCORE_THRESHOLD || clip_x(left)>=clip_x(right) || clip_y(top)>=clip_y(bottom))state<=0;
     else if(count<20)state<=4;
     else begin scan<=0;min_index<=0;min_score<=16'hffff;min_order<=0;state<=5;end
    end
    4:begin cand_box[count]<=new_box;cand_score[count]<=new_score;cand_order[count]<=new_order;cand_class[count]<=new_class;count<=count+1'b1;state<=0;end
    5:begin
     if(cand_score[scan]<min_score || (cand_score[scan]==min_score && cand_order[scan]>min_order))begin min_score<=cand_score[scan];min_index<=scan;min_order<=cand_order[scan];end
     if(scan==19)state<=6;else scan<=scan+1'b1;
    end
    6:begin if(new_score>min_score)begin cand_box[min_index]<=new_box;cand_score[min_index]<=new_score;cand_order[min_index]<=new_order;cand_class[min_index]<=new_class;end state<=0;end
    20:begin
     if(scan<count && (cand_score[scan]>best_score || (cand_score[scan]==best_score && cand_order[scan]<best_order)))begin best_score<=cand_score[scan];best_index<=scan;best_order<=cand_order[scan];end
     if(scan==19)state<=21;else scan<=scan+1'b1;
    end
    21:begin
     if(best_score==0 || kept==5)state<=31;
     else begin
      ref_box<=cand_box[best_index];working[kept*48+:48]<=cand_box[best_index];kept<=kept+1'b1;
      working_classes[kept*3+:3]<=cand_class[best_index];working_scores[kept*16+:16]<=cand_score[best_index];
      cand_score[best_index]<=0;mul_a<=cand_box[best_index][23:12]-cand_box[best_index][47:36];
      mul_b<=cand_box[best_index][11:0]-cand_box[best_index][35:24];state<=22;
     end
    end
    22:state<=23;
    23:begin ref_area<=mul_q;scan<=0;state<=24;end
    24:begin
     if(scan>=count || cand_score[scan]==0)state<=30;
     else begin
      mul_a<=bx1-bx0;mul_b<=by1-by0;
      inter_w<=ix1>ix0?ix1-ix0:0;inter_h<=iy1>iy0?iy1-iy0:0;state<=25;
     end
    end
    25:state<=26;
    26:begin cand_area<=mul_q;mul_a<=inter_w;mul_b<=inter_h;state<=27;end
    27:state<=28;
    28:begin intersection<=mul_q;union_area<=ref_area+cand_area-mul_q;state<=29;end
    29:begin if(({9'b0,intersection}<<8)>u103)cand_score[scan]<=0;state<=30;end
    30:begin
     if(scan==19)begin scan<=0;best_score<=0;best_index<=0;best_order<=511;state<=20;end
     else begin scan<=scan+1'b1;state<=24;end
    end
    31:begin if(!overrun)begin boxes<=working;classes<=working_classes;scores<=working_scores;commit<=1;end busy<=0;state<=0;end
    default:;
   endcase
   if(i_start)begin
    busy<=1;state<=0;count<=0;finish_pending<=0;overrun<=0;frame_id<=i_frame;cfg_id<=i_cfg;
    for(k=0;k<20;k=k+1)cand_score[k]<=0;
   end
   if(i_abort)begin busy<=0;state<=0;finish_pending<=0;overrun<=0;end
  end
 end
endmodule
