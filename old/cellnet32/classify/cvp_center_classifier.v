// Fixed center480 sampling never uses detector geometry. Detector boxes remain
// visible, with the single field class attached only to the nearest central box.
module cvp_center_classifier #(parameter N=5,W=1280,H=720,CROP=480,DETECT_TTL=3,
 parameter WROM_FILE="../../../user_source/hdl_source/classify/model/wrom.hex")(
 input clk,rst_n,input i_commit,input [N*48-1:0] i_boxes,input [31:0] i_detect_frame,input [15:0] i_detect_cfg,
 input i_valid,i_sof,input [11:0] i_x,i_y,input [23:0] i_rgb,
 input [31:0] i_frame,input [15:0] i_cfg,input [63:0] i_ticks,
 output wire [N*48-1:0] o_boxes,output reg [N*3-1:0] o_classes,output reg [N-1:0] o_known,
 output reg o_result_valid,input i_result_ready,output reg [31:0] o_result_frame,
 output reg [15:0] o_result_roi,output reg [7:0] o_result_class,
 output reg [63:0] o_result_bbox,o_result_tick
);
 localparam X0=(W-CROP)/2,Y0=(H-CROP)/2;
 localparam [11:0] SX0=X0,SY0=Y0,SX1=X0+CROP-1,SY1=Y0+CROP-1;
 localparam [12:0] CENTER_X=W,CENTER_Y=H;
 localparam [47:0] FIXED_BOX={SX0,SY0,SX1,SY1};
 reg snapshot;reg [31:0] patch_df;reg [15:0] patch_cfg;
 reg [N*48-1:0] boxes;reg [31:0] box_frame;reg [15:0] box_cfg;
 wire eof=i_valid && i_x==W-1 && i_y==H-1;
 wire done,busy,result,start,we;wire [2:0] pred,raw_class,stable_class;wire stable_known;
 wire [31:0] token,capture_frame;wire [15:0] result_cfg;wire [47:0] bbox;
 wire [11:0] addr;wire [7:0] data;
 wire boxes_current=box_cfg==i_cfg && i_frame-box_frame<=DETECT_TTL;
 assign o_boxes=boxes_current?boxes:{N*48{1'b1}};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin snapshot<=0;patch_df<=0;patch_cfg<=0;boxes<={N*48{1'b1}};box_frame<=0;box_cfg<=0;end
  else begin
   snapshot<=eof;
   if(eof)begin patch_df<=i_frame;patch_cfg<=i_cfg;end
   if(i_commit && i_detect_cfg==i_cfg && i_frame-i_detect_frame<=2)begin
    boxes<=i_boxes;box_frame<=i_detect_frame;box_cfg<=i_detect_cfg;
   end
  end
 end
 cvp_roi_rgb32 #(.N(1),.W(W),.H(H),.MARGIN(0)) crop(.clk(clk),.rst_n(rst_n),.i_snapshot(snapshot),
  .i_boxes(FIXED_BOX),.i_tokens(32'hc4800001),.i_detect_frame(patch_df),.i_box_cfg(patch_cfg),
  .i_valid(i_valid),.i_sof(i_sof),.i_x(i_x),.i_y(i_y),.i_rgb(i_rgb),.i_frame(i_frame),.i_cfg(i_cfg),
  .i_busy(busy),.i_done(done),.i_pred(pred),.o_img_we(we),.o_img_addr(addr),.o_img_data(data),.o_start(start),
  .o_result(result),.o_token(token),.o_capture_frame(capture_frame),.o_cfg(result_cfg),.o_class(raw_class),.o_bbox(bbox),
  .o_dropped(),.o_aborted());
 cellnet32_core #(.WROM_FILE(WROM_FILE)) cnn(.clk(clk),.rst_n(rst_n),.img_waddr(addr),.img_wdata(data),
  .img_we(we),.start(start),.busy(busy),.done(done),.pred(pred),.logits_flat());
 cvp_class_confirm confirm(.clk(clk),.rst_n(rst_n),.i_result(result),.i_class(raw_class),
  .i_capture_frame(capture_frame),.i_frame(i_frame),.i_cfg(i_cfg),.i_result_cfg(result_cfg),
  .o_class(stable_class),.o_known(stable_known));
 // One candidate per four clocks: coordinate sum, absolute delta, distance,
 // compare. No five-comparator cascade on the 100MHz OSD input path.
 integer k;reg [2:0] nearest,scan,candidate,state;reg selected,found,valid_box;
 reg [12:0] best,distance,sx,sy,dx,dy;
 wire [47:0] b=boxes[scan*48+:48];
 wire wins=valid_box && sx>=2*X0 && sx<2*(X0+CROP) &&
           sy>=2*Y0 && sy<2*(Y0+CROP) && distance<best;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   nearest<=0;scan<=0;candidate<=0;state<=0;selected<=0;found<=0;valid_box<=0;
   best<=8191;distance<=0;sx<=0;sy<=0;dx<=0;dy<=0;
  end else if(i_commit && i_detect_cfg==i_cfg && i_frame-i_detect_frame<=2)begin
   state<=1;scan<=0;best<=8191;found<=0;selected<=0;
  end else case(state)
   1:begin
    sx<={1'b0,b[47:36]}+{1'b0,b[23:12]};sy<={1'b0,b[35:24]}+{1'b0,b[11:0]};
    valid_box<=b[47:36]<b[23:12] && b[35:24]<b[11:0] && b[23:12]<W && b[11:0]<H;
    state<=2;
   end
   2:begin dx<=sx<CENTER_X?CENTER_X-sx:sx-CENTER_X;dy<=sy<CENTER_Y?CENTER_Y-sy:sy-CENTER_Y;state<=3;end
   3:begin distance<=dx+dy;state<=4;end
   4:begin
    if(wins)begin best<=distance;candidate<=scan;found<=1;end
    if(scan==N-1)begin nearest<=wins?scan:candidate;selected<=found||wins;state<=0;end
    else begin scan<=scan+1'b1;state<=1;end
   end
   default:state<=0;
  endcase
 end
 always @*begin
  // Reserved class 6 means draw the box without a text panel.
  for(k=0;k<N;k=k+1)begin o_classes[k*3+:3]=3'd6;o_known[k]=1;end
  if(selected && boxes_current)begin o_classes[nearest*3+:3]=stable_class;o_known[nearest]=stable_known;end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin o_result_valid<=0;o_result_frame<=0;o_result_roi<=0;o_result_class<=0;o_result_bbox<=0;o_result_tick<=0;end
  else begin
   if(o_result_valid&&i_result_ready)o_result_valid<=0;
   if(result&&(!o_result_valid||i_result_ready))begin
    o_result_valid<=1;o_result_frame<=capture_frame;o_result_roi<=16'hc480;o_result_class<={5'd0,raw_class};
    o_result_bbox<={4'd0,bbox[47:36],4'd0,bbox[35:24],4'd0,bbox[23:12],4'd0,bbox[11:0]};o_result_tick<=i_ticks;
   end
  end
 end
endmodule
