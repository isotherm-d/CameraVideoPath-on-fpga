module cvp_cellnet32 #(parameter N=5,W=1280,H=720,
 parameter WROM_FILE="../../../user_source/hdl_source/classify/model/wrom.hex")(
 input clk,rst_n,input i_commit,input [N*48-1:0] i_boxes,input [31:0] i_detect_frame,input [15:0] i_detect_cfg,
 input i_valid,i_sof,input [11:0] i_x,i_y,input [23:0] i_rgb,
 input [31:0] i_frame,input [15:0] i_cfg,input [63:0] i_ticks,
 output [N*48-1:0] o_boxes,output [N*3-1:0] o_classes,output [N-1:0] o_known,
 output reg o_result_valid,input i_result_ready,output reg [31:0] o_result_frame,
 output reg [15:0] o_result_roi,output reg [7:0] o_result_class,
 output reg [63:0] o_result_bbox,o_result_tick
);
 wire snapshot;wire [N*32-1:0] tokens;wire [31:0] detect_frame;wire [15:0] box_cfg;
 wire done,busy,result,start,we;wire [2:0] pred,klass;
 wire [31:0] token,capture_frame;wire [15:0] cfg;wire [47:0] bbox;
 wire [11:0] addr;wire [7:0] data;
 cvp_cell_tracks #(.N(N)) tracks(.clk(clk),.rst_n(rst_n),.i_commit(i_commit),.i_boxes(i_boxes),
  .i_detect_frame(i_detect_frame),.i_frame(i_frame),.i_cfg(i_cfg),.i_detect_cfg(i_detect_cfg),.i_result(result),
  .i_token(token),.i_capture_frame(capture_frame),.i_result_cfg(cfg),.i_class(klass),
  .o_snapshot(snapshot),.o_boxes(o_boxes),.o_tokens(tokens),.o_classes(o_classes),
  .o_class_valid(o_known),.o_detect_frame(detect_frame),.o_cfg(box_cfg));
 cvp_roi_rgb32 #(.N(N),.W(W),.H(H)) crop(.clk(clk),.rst_n(rst_n),.i_snapshot(snapshot),
  .i_boxes(o_boxes),.i_tokens(tokens),.i_detect_frame(detect_frame),.i_box_cfg(box_cfg),
  .i_valid(i_valid),.i_sof(i_sof),.i_x(i_x),.i_y(i_y),.i_rgb(i_rgb),.i_frame(i_frame),.i_cfg(i_cfg),
  .i_busy(busy),.i_done(done),.i_pred(pred),.o_img_we(we),.o_img_addr(addr),.o_img_data(data),.o_start(start),
  .o_result(result),.o_token(token),.o_capture_frame(capture_frame),.o_cfg(cfg),.o_class(klass),.o_bbox(bbox),
  .o_dropped(),.o_aborted());
 cellnet32_core #(.WROM_FILE(WROM_FILE)) cnn(.clk(clk),.rst_n(rst_n),.img_waddr(addr),
  .img_wdata(data),.img_we(we),.start(start),.busy(busy),.done(done),.pred(pred),.logits_flat());
 // Hold one diagnostic descriptor under backpressure. Cache writes are separate
 // and never wait for UDP status; zero score means no calibrated confidence.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin o_result_valid<=0;o_result_frame<=0;o_result_roi<=0;o_result_class<=0;
   o_result_bbox<=0;o_result_tick<=0;end
  else begin
   if(o_result_valid&&i_result_ready)o_result_valid<=0;
   if(result&&(!o_result_valid||i_result_ready))begin
    o_result_valid<=1;o_result_frame<=capture_frame;o_result_roi<=token[15:0];o_result_class<={5'd0,klass};
    o_result_bbox<={4'd0,bbox[47:36],4'd0,bbox[35:24],4'd0,bbox[23:12],4'd0,bbox[11:0]};o_result_tick<=i_ticks;
   end
  end
 end
endmodule
