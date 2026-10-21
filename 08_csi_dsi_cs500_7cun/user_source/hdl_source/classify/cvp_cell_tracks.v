// Stable track slots, reciprocal unique geometry matching, and bounded temporal
// confirmation. Hidden tracks survive brief detector misses. The legacy
// default hides them; YOLO may explicitly retain their display through misses.
module cvp_cell_tracks #(parameter N=5, TTL=15, MATCH_DIST=48, SIZE_DIST=32,PIPE_MATCH=0,
 parameter MISSED_FRAMES=2, INIT_HITS=2, SWITCH_HITS=3, HOLD_MISSES=0)(
 input clk,rst_n, input i_commit, input [N*48-1:0] i_boxes,
 input [31:0] i_detect_frame,i_frame, input [15:0] i_cfg,i_detect_cfg,
 input i_result, input [31:0] i_token,i_capture_frame,
 input [15:0] i_result_cfg, input [2:0] i_class,
 output reg o_snapshot, output wire [N*48-1:0] o_boxes,
 output wire [N*32-1:0] o_tokens, output wire [N*3-1:0] o_classes,
 output wire [N-1:0] o_class_valid, output reg [31:0] o_detect_frame,
 output reg [15:0] o_cfg
);
 reg [47:0] box[0:N-1], incoming[0:N-1];
 reg [31:0] token[0:N-1], result_frame[0:N-1], last_seen[0:N-1], pending_frame;
 reg [28:0] serial;
 reg [2:0] klass[0:N-1], challenger[0:N-1], votes[0:N-1];
 reg [N-1:0] known,present,seen_result,matched;
 reg [15:0] pending_cfg;
 reg [2:0] nc[0:N-1],oc[0:N-1],mi[0:N-1];
 reg [3:0] state;reg [2:0] a,b;
 reg have_snapshot;
 // Optional multi-cycle geometry path for 100MHz YOLO integration. The default
 // schedule remains unchanged for the original classifier regression benches.
 reg [47:0] pair_a,pair_b;reg pair_eligible,pair_valid,pair_close;
 reg [12:0] sum_ax,sum_ay,sum_bx,sum_by,width_a,height_a,width_b,height_b;
 reg signed [13:0] delta_x,delta_y,delta_w,delta_h;
 integer k,q,free_slot;
 function valid_box; input [47:0] v; begin
  valid_box=v[47:36]<v[23:12] && v[35:24]<v[11:0] && v[23:12]<1280 && v[11:0]<720;
 end endfunction
 function newer; input [31:0] x,y; reg [31:0] d; begin
  d=x-y;newer=d!=0 && !d[31];
 end endfunction
 function close_box; input [47:0] u,v;
  reg signed [13:0] dx,dy,dw,dh;
  begin
   dx=({2'd0,u[47:36]}+{2'd0,u[23:12]})-({2'd0,v[47:36]}+{2'd0,v[23:12]});
   dy=({2'd0,u[35:24]}+{2'd0,u[11:0]})-({2'd0,v[35:24]}+{2'd0,v[11:0]});
   dw=({2'd0,u[23:12]}-{2'd0,u[47:36]})-({2'd0,v[23:12]}-{2'd0,v[47:36]});
   dh=({2'd0,u[11:0]}-{2'd0,u[35:24]})-({2'd0,v[11:0]}-{2'd0,v[35:24]});
   close_box=valid_box(u)&&valid_box(v)&&dx<=MATCH_DIST&&dx>=-MATCH_DIST&&
    dy<=MATCH_DIST&&dy>=-MATCH_DIST&&dw<=SIZE_DIST&&dw>=-SIZE_DIST&&dh<=SIZE_DIST&&dh>=-SIZE_DIST;
  end
 endfunction
 // New detections take an empty slot first, otherwise evict a hidden track.
 // A visible, uniquely matched target is never evicted by a new target.
 always @* begin
  free_slot=-1;
  for(q=N-1;q>=0;q=q-1)if(!present[q])free_slot=q;
  for(q=N-1;q>=0;q=q-1)if(!valid_box(box[q]))free_slot=q;
 end
 genvar g;
 generate for(g=0;g<N;g=g+1)begin:G_OUT
  wire visible=present[g] || (HOLD_MISSES && valid_box(box[g]));
  assign o_boxes[g*48+:48]=visible?box[g]:48'hffffffffffff;
  assign o_tokens[g*32+:32]=token[g];
  assign o_classes[g*3+:3]=klass[g];
  assign o_class_valid[g]=visible && known[g] && seen_result[g] &&
   (i_frame-result_frame[g]<=TTL) && o_cfg==i_cfg;
 end endgenerate
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=0;a<=0;b<=0;known<=0;present<=0;seen_result<=0;matched<=0;serial<=1;
   o_snapshot<=0;o_cfg<=0;o_detect_frame<=0;pending_frame<=0;pending_cfg<=0;have_snapshot<=0;
   pair_a<=0;pair_b<=0;pair_eligible<=0;pair_valid<=0;pair_close<=0;
   sum_ax<=0;sum_ay<=0;sum_bx<=0;sum_by<=0;width_a<=0;height_a<=0;width_b<=0;height_b<=0;
   delta_x<=0;delta_y<=0;delta_w<=0;delta_h<=0;
   for(k=0;k<N;k=k+1)begin
    box[k]<=48'hffffffffffff;incoming[k]<=48'hffffffffffff;
    token[k]<=0;result_frame[k]<=0;last_seen[k]<=0;klass[k]<=0;challenger[k]<=0;votes[k]<=0;
    nc[k]<=0;oc[k]<=0;mi[k]<=0;
   end
  end else begin
   o_snapshot<=0;
   // Count distinct, chronological inference results, never display frames or
   // repeated status descriptors. TTL also prevents confirmation across a gap.
   if(i_result && i_result_cfg==o_cfg && i_result_cfg==i_cfg && i_class<5 &&
      i_frame-i_capture_frame<=TTL && i_token!=0)
    for(k=0;k<N;k=k+1)if(token[k]==i_token && valid_box(box[k]) &&
       (!seen_result[k] || newer(i_capture_frame,result_frame[k])))begin
     seen_result[k]<=1;result_frame[k]<=i_capture_frame;
     if(!known[k] || !seen_result[k] || i_frame-result_frame[k]>TTL)begin
      known[k]<=0;
      if(INIT_HITS<=1 || (seen_result[k] && i_frame-result_frame[k]<=TTL &&
          votes[k]!=0 && challenger[k]==i_class && votes[k]>=INIT_HITS-1))begin
       known[k]<=1;klass[k]<=i_class;votes[k]<=0;
      end else if(seen_result[k] && i_frame-result_frame[k]<=TTL &&
                  votes[k]!=0 && challenger[k]==i_class)votes[k]<=votes[k]+1'b1;
      else begin challenger[k]<=i_class;votes[k]<=1;end
     end else if(i_class==klass[k])begin challenger[k]<=i_class;votes[k]<=0;end
     else if(SWITCH_HITS<=1 || (votes[k]!=0 && challenger[k]==i_class && votes[k]>=SWITCH_HITS-1))begin
      klass[k]<=i_class;votes[k]<=0;
     end else if(votes[k]!=0 && challenger[k]==i_class)votes[k]<=votes[k]+1'b1;
     else begin challenger[k]<=i_class;votes[k]<=1;end
    end
   case(state)
    0:if(i_commit && i_detect_cfg==i_cfg && i_frame-i_detect_frame<=2 &&
       (!have_snapshot || i_detect_cfg!=o_cfg || newer(i_detect_frame,o_detect_frame)))begin
     pending_frame<=i_detect_frame;pending_cfg<=i_detect_cfg;
     for(k=0;k<N;k=k+1)begin incoming[k]<=i_boxes[k*48+:48];nc[k]<=0;oc[k]<=0;mi[k]<=0;end
     a<=0;b<=0;matched<=0;state<=1;
    end
    1:begin
     if(PIPE_MATCH)begin
      pair_a<=incoming[a];pair_b<=box[b];pair_eligible<=pending_cfg==o_cfg && pending_frame-last_seen[b]<=MISSED_FRAMES+1;state<=6;
     end else begin
      if(pending_cfg==o_cfg && pending_frame-last_seen[b]<=MISSED_FRAMES+1 && close_box(incoming[a],box[b]))begin
       nc[a]<=nc[a]+1'b1;oc[b]<=oc[b]+1'b1;mi[a]<=b;
      end
      if(b==N-1)begin b<=0;if(a==N-1)begin a<=0;state<=2;end else a<=a+1;end else b<=b+1;
     end
    end
    6:begin
     sum_ax<={1'b0,pair_a[47:36]}+{1'b0,pair_a[23:12]};sum_ay<={1'b0,pair_a[35:24]}+{1'b0,pair_a[11:0]};
     sum_bx<={1'b0,pair_b[47:36]}+{1'b0,pair_b[23:12]};sum_by<={1'b0,pair_b[35:24]}+{1'b0,pair_b[11:0]};
     width_a<={1'b0,pair_a[23:12]}-{1'b0,pair_a[47:36]};height_a<={1'b0,pair_a[11:0]}-{1'b0,pair_a[35:24]};
     width_b<={1'b0,pair_b[23:12]}-{1'b0,pair_b[47:36]};height_b<={1'b0,pair_b[11:0]}-{1'b0,pair_b[35:24]};
     pair_valid<=valid_box(pair_a)&&valid_box(pair_b);state<=7;
    end
    7:begin
     delta_x<=$signed({1'b0,sum_ax})-$signed({1'b0,sum_bx});delta_y<=$signed({1'b0,sum_ay})-$signed({1'b0,sum_by});
     delta_w<=$signed({1'b0,width_a})-$signed({1'b0,width_b});delta_h<=$signed({1'b0,height_a})-$signed({1'b0,height_b});state<=8;
    end
    8:begin
     pair_close<=pair_eligible && pair_valid && delta_x<=MATCH_DIST && delta_x>=-MATCH_DIST && delta_y<=MATCH_DIST && delta_y>=-MATCH_DIST &&
                 delta_w<=SIZE_DIST && delta_w>=-SIZE_DIST && delta_h<=SIZE_DIST && delta_h>=-SIZE_DIST;state<=9;
    end
    9:begin
     if(pair_close)begin nc[a]<=nc[a]+1'b1;oc[b]<=oc[b]+1'b1;mi[a]<=b;end
     if(b==N-1)begin b<=0;if(a==N-1)begin a<=0;state<=2;end else begin a<=a+1'b1;state<=1;end end
     else begin b<=b+1'b1;state<=1;end
    end
    2:begin
     // Identity data stays in its slot when the detector changes slot order.
     if(nc[a]==1 && oc[mi[a]]==1)begin
      box[mi[a]]<=incoming[a];last_seen[mi[a]]<=pending_frame;matched[mi[a]]<=1;
     end
     if(a==N-1)begin state<=3;end else a<=a+1'b1;
    end
    3:begin
     present<=matched;
     for(k=0;k<N;k=k+1)if(!matched[k] && (pending_cfg!=o_cfg ||
         pending_frame-last_seen[k]>MISSED_FRAMES || oc[k]!=0))begin
      // Ambiguity and long disappearance retire the old generation immediately.
      box[k]<=48'hffffffffffff;token[k]<=0;known[k]<=0;seen_result[k]<=0;votes[k]<=0;
     end
     a<=0;state<=4;
    end
    4:begin
     if(valid_box(incoming[a]) && !(nc[a]==1 && oc[mi[a]]==1) && free_slot>=0)begin
      box[free_slot]<=incoming[a];token[free_slot]<={serial,a};last_seen[free_slot]<=pending_frame;
      present[free_slot]<=1;known[free_slot]<=0;seen_result[free_slot]<=0;
      klass[free_slot]<=0;challenger[free_slot]<=0;votes[free_slot]<=0;result_frame[free_slot]<=0;
     end
     if(a==N-1)state<=5;else a<=a+1'b1;
    end
    5:begin
     serial<=serial+1'b1;o_cfg<=pending_cfg;o_detect_frame<=pending_frame;
     o_snapshot<=1;have_snapshot<=1;state<=0;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
