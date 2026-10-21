// Bind each YOLO class to its geometry-matched identity, then reuse the proven
// per-track 2-hit initial / 3-hit switch policy. No image crop or second CNN.
module cvp_yolo_tracks #(parameter N=5,DETECT_TTL=5,SINGLE_TARGET=0)(
 input clk,rst_n,input i_commit,input [N*48-1:0] i_boxes,input [N*3-1:0] i_classes,
 input [31:0] i_detect_frame,i_frame,input [15:0] i_cfg,i_detect_cfg,input [63:0] i_ticks,
 output [N*48-1:0] o_boxes,output [N*3-1:0] o_classes,output [N-1:0] o_known,
 output reg o_result_valid,input i_result_ready,output reg [31:0] o_result_frame,
 output reg [15:0] o_result_roi,output reg [7:0] o_result_class,
 output reg [63:0] o_result_bbox,o_result_tick
);
 wire snapshot;wire [N*48-1:0] track_boxes;wire [N*32-1:0] tokens;wire [N*3-1:0] track_classes;
 wire [31:0] track_frame;wire [15:0] track_cfg;
 reg pending,seen;reg [31:0] previous_frame,source_frame;reg [15:0] source_cfg;
 reg [N*48-1:0] incoming;reg [N*3-1:0] incoming_classes;reg [63:0] source_ticks;
 reg vote;reg [31:0] vote_token;reg [2:0] vote_class;
 wire [31:0] delta=i_detect_frame-previous_frame;
 wire accept=i_commit && !pending && i_detect_cfg==i_cfg && i_frame-i_detect_frame<=2 &&
             (!seen || i_detect_cfg!=source_cfg || (delta!=0 && !delta[31]));
 reg display_valid;reg [N*48-1:0] display_boxes;reg [N*3-1:0] display_classes;
 reg [N-1:0] display_known;reg [31:0] display_frame;reg [15:0] display_cfg;
 wire fresh=display_valid && display_cfg==i_cfg && i_frame-display_frame<=DETECT_TTL;
 wire [N-1:0] known;
 // Publish only a finished transaction, then hold it across every video frame.
 // At 15Hz, source frames differ by two: hold misses at +2/+4, retire at +6.
 assign o_boxes=fresh?display_boxes:{N*48{1'b1}};
 assign o_classes=display_classes;
 assign o_known=fresh?display_known:0;
 cvp_cell_tracks #(.N(N),.TTL(15),.MATCH_DIST(96),.SIZE_DIST(64),.MISSED_FRAMES(5),.PIPE_MATCH(1),.HOLD_MISSES(1)) tracks(
  .clk(clk),.rst_n(rst_n),.i_commit(accept),.i_boxes(i_boxes),.i_detect_frame(i_detect_frame),.i_frame(i_frame),
  .i_cfg(i_cfg),.i_detect_cfg(i_detect_cfg),.i_result(vote),.i_token(vote_token),.i_capture_frame(source_frame),
  .i_result_cfg(source_cfg),.i_class(vote_class),.o_snapshot(snapshot),.o_boxes(track_boxes),.o_tokens(tokens),
  .o_classes(track_classes),.o_class_valid(known),.o_detect_frame(track_frame),.o_cfg(track_cfg));
 reg [3:0] state;reg [2:0] slot,search;reg found;reg [2:0] matched_class;reg [47:0] matched_box;
 // Selection scans five stable identities over multiple clocks. Keep the
 // selected generation through short misses; choose nearest center only when
 // it is gone. No combinational five-way distance chain in the video path.
 reg selected_valid;reg [31:0] selected_token;
 reg [2:0] pick;reg candidate_valid,candidate_held,candidate_known;
 reg [47:0] candidate_box,best_box,held_box;reg [2:0] candidate_class,best_class,held_class;
 reg [31:0] candidate_token,best_token,held_token;reg best_valid,held_valid,best_known,held_known;
 reg [12:0] center_x2,center_y2,dist_x,dist_y;reg [13:0] distance,best_distance;
 wire [47:0] b=incoming[search*48+:48];
 wire valid_box=b[47:36]<b[23:12] && b[35:24]<b[11:0] && b[23:12]<1280 && b[11:0]<720;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending<=0;seen<=0;previous_frame<=0;source_frame<=0;source_cfg<=0;incoming<={N*48{1'b1}};incoming_classes<=0;source_ticks<=0;
   vote<=0;vote_token<=0;vote_class<=0;state<=0;slot<=0;search<=0;found<=0;matched_class<=0;matched_box<=0;
   display_valid<=0;display_boxes<={N*48{1'b1}};display_classes<=0;display_known<=0;display_frame<=0;display_cfg<=0;
   selected_valid<=0;selected_token<=0;pick<=0;candidate_valid<=0;candidate_held<=0;candidate_known<=0;
   candidate_box<=0;best_box<=0;held_box<=0;candidate_class<=0;best_class<=0;held_class<=0;
   candidate_token<=0;best_token<=0;held_token<=0;best_valid<=0;held_valid<=0;best_known<=0;held_known<=0;
   center_x2<=0;center_y2<=0;dist_x<=0;dist_y<=0;distance<=0;best_distance<=0;
   o_result_valid<=0;o_result_frame<=0;o_result_roi<=0;o_result_class<=0;o_result_bbox<=0;o_result_tick<=0;
  end else begin
   vote<=0;
   if(o_result_valid && i_result_ready)o_result_valid<=0;
   if(accept)begin
    pending<=1;seen<=1;previous_frame<=i_detect_frame;source_frame<=i_detect_frame;source_cfg<=i_detect_cfg;
    incoming<=i_boxes;incoming_classes<=i_classes;source_ticks<=i_ticks;
   end
   case(state)
    0:if(snapshot && pending)begin slot<=0;search<=0;found<=0;state<=1;end
    1:begin
     if(valid_box && b==track_boxes[slot*48+:48])begin
      found<=1;matched_class<=incoming_classes[search*3+:3];matched_box<=b;
     end
     if(search==N-1)state<=2;else search<=search+1'b1;
    end
    2:begin
     if(found && matched_class<5 && source_cfg==i_cfg)begin
      vote<=1;vote_token<=tokens[slot*32+:32];vote_class<=matched_class;
      // Diagnostic backpressure never holds up detection or class voting.
      if(!o_result_valid || i_result_ready)begin
       o_result_valid<=1;o_result_frame<=source_frame;o_result_roi<={13'd0,slot};o_result_class<={5'd0,matched_class};
       o_result_bbox<={4'd0,matched_box[47:36],4'd0,matched_box[35:24],4'd0,matched_box[23:12],4'd0,matched_box[11:0]};o_result_tick<=source_ticks;
      end
     end
     if(slot==N-1)state<=3;
     else begin slot<=slot+1'b1;search<=0;found<=0;state<=1;end
    end
    3:state<=4; // Let the final vote update the track before publication.
    4:begin
     if(SINGLE_TARGET)begin pick<=0;best_valid<=0;held_valid<=0;state<=5;end
     else begin
      display_boxes<=track_boxes;display_classes<=track_classes;display_known<=known;
      display_frame<=track_frame;display_cfg<=track_cfg;display_valid<=1;
      pending<=0;state<=0;
     end
    end
    5:begin
     candidate_box<=track_boxes[pick*48+:48];candidate_class<=track_classes[pick*3+:3];candidate_known<=known[pick];
     candidate_token<=tokens[pick*32+:32];
     candidate_valid<=track_boxes[pick*48+47-:12]<track_boxes[pick*48+23-:12] &&
                      track_boxes[pick*48+35-:12]<track_boxes[pick*48+11-:12] && tokens[pick*32+:32]!=0;
     candidate_held<=selected_valid && display_cfg==track_cfg && tokens[pick*32+:32]==selected_token;
     center_x2<={1'b0,track_boxes[pick*48+47-:12]}+{1'b0,track_boxes[pick*48+23-:12]};
     center_y2<={1'b0,track_boxes[pick*48+35-:12]}+{1'b0,track_boxes[pick*48+11-:12]};state<=6;
    end
    6:begin dist_x<=center_x2>=1280?center_x2-13'd1280:13'd1280-center_x2;
            dist_y<=center_y2>=720?center_y2-13'd720:13'd720-center_y2;state<=7;end
    7:begin distance<={1'b0,dist_x}+{1'b0,dist_y};state<=8;end
    8:begin
     if(candidate_valid)begin
      if(!best_valid || distance<best_distance)begin
       best_valid<=1;best_distance<=distance;best_box<=candidate_box;best_class<=candidate_class;
       best_known<=candidate_known;best_token<=candidate_token;
      end
      if(candidate_held)begin held_valid<=1;held_box<=candidate_box;held_class<=candidate_class;
       held_known<=candidate_known;held_token<=candidate_token;end
     end
     if(pick==N-1)state<=9;else begin pick<=pick+1'b1;state<=5;end
    end
    9:begin
     display_boxes<={N*48{1'b1}};display_classes<=0;display_known<=0;
     selected_valid<=held_valid||best_valid;
     if(held_valid||best_valid)begin
      display_boxes[0+:48]<=held_valid?held_box:best_box;
      display_classes[0+:3]<=held_valid?held_class:best_class;
      display_known[0]<=held_valid?held_known:best_known;selected_token<=held_valid?held_token:best_token;
     end else selected_token<=0;
     display_frame<=track_frame;display_cfg<=track_cfg;display_valid<=1;pending<=0;state<=0;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
