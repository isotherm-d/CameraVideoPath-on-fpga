// One independent detector context, sampled every two frames (15Hz at 30fps).
module cvp_yolo160_detector #(parameter FRAME_INTERVAL=2)(
 input clk,rst_n,input i_valid,input [11:0] i_x,i_y,input [23:0] i_rgb,
 input [31:0] i_frame,input [15:0] i_cfg,
 output [239:0] o_boxes,output o_commit,output [31:0] o_frame,output [15:0] o_cfg,
 output [14:0] o_classes,output [79:0] o_scores,
 output wire o_busy,output reg [31:0] o_aborts
);
 wire first_busy,first_done,first_abort,we,core_busy,core_done,post_busy,post_commit,overrun;
 wire [12:0] addr;wire [31:0] data,source_frame;wire [15:0] source_cfg;
 wire lv;wire [3:0] lx,ly,layer;wire [4:0] channel;wire signed [15:0] logit;
 reg [23:0] watchdog;
 wire abort=first_abort || ((core_busy || post_busy) &&
            (i_cfg!=source_cfg || watchdog>=6000000 || i_frame-source_frame>3));
 assign o_busy=first_busy || core_busy || post_busy;
 assign o_commit=post_commit && !abort && !overrun;
 yolo160_first #(.FRAME_INTERVAL(FRAME_INTERVAL),.FULL_FRAME(1)) first(.clk(clk),.rst_n(rst_n),.i_enable(!core_busy && !post_busy),
  .i_valid(i_valid),.i_x(i_x),.i_y(i_y),.i_rgb(i_rgb),.i_frame(i_frame),.i_cfg(i_cfg),
  .busy(first_busy),.done(first_done),.aborted(first_abort),.we(we),.addr(addr),.data(data),.frame_id(source_frame),.cfg_id(source_cfg));
 yolo160_core core(.clk(clk),.rst_n(rst_n),.i_we(we),.i_addr(addr),.i_data(data),.i_start(first_done),.i_abort(abort),
  .busy(core_busy),.done(core_done),.logit_valid(lv),.logit_x(lx),.logit_y(ly),.logit_channel(channel),.logit(logit),.layer_done(),.layer(layer));
 yolo160_boxes post(.clk(clk),.rst_n(rst_n),.i_start(first_done),.i_abort(abort),.i_frame(source_frame),.i_cfg(source_cfg),
  .i_valid(lv),.i_x(lx),.i_y(ly),.i_channel(channel),.i_logit(logit),.i_done(core_done),
  .busy(post_busy),.commit(post_commit),.boxes(o_boxes),.classes(o_classes),.scores(o_scores),.frame_id(o_frame),.cfg_id(o_cfg),.overrun(overrun));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin watchdog<=0;o_aborts<=0;end
  else begin
   if(core_busy || post_busy)watchdog<=watchdog+1'b1;else watchdog<=0;
   if(abort)o_aborts<=o_aborts+1'b1;
  end
 end
endmodule
