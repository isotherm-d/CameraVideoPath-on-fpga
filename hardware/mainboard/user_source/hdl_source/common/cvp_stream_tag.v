// Attach canonical coordinates and frame/config identity without changing RGB.
module cvp_stream_tag #(parameter W=1280,H=720)(
 input clk,rst_n,i_valid,input [23:0] i_rgb,input i_sof,
 input [15:0] i_cfg_id,input [7:0] i_mode,
 output reg o_valid,output reg [23:0] o_rgb,output reg o_sof,o_eol,o_eof,
 output reg [11:0] o_x,o_y,output reg [31:0] o_frame_id,
 output reg [15:0] o_cfg_id,output reg [7:0] o_mode,
 output reg [63:0] o_ticks,output reg [63:0] o_capture_tick,
 output reg o_frame_error
);
 reg [11:0] nx,ny;reg started;
 wire [11:0] x=i_sof?12'd0:nx,y=i_sof?12'd0:ny;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   o_ticks<=0;o_capture_tick<=0;o_frame_id<=32'hffffffff;o_cfg_id<=0;o_mode<=0;
   nx<=0;ny<=0;started<=0;o_valid<=0;o_rgb<=0;o_sof<=0;o_eol<=0;o_eof<=0;
   o_x<=0;o_y<=0;o_frame_error<=0;
  end else begin
   o_ticks<=o_ticks+1'b1;
   o_valid<=i_valid&&(started||i_sof);o_sof<=i_valid&&i_sof;
   o_eol<=i_valid&&(started||i_sof)&&x==W-1;
   o_eof<=i_valid&&(started||i_sof)&&x==W-1&&y==H-1;o_frame_error<=0;
   if(i_valid)begin
    o_rgb<=i_rgb;o_x<=x;o_y<=y;
    if(i_sof)begin
     o_frame_error<=started&&(nx!=0||ny!=0);
     started<=1;o_frame_id<=o_frame_id+1'b1;
     o_capture_tick<=o_ticks;o_cfg_id<=i_cfg_id;o_mode<=i_mode;
    end
    if(started||i_sof)begin
     if(x==W-1)begin nx<=0;ny<=y==H-1?12'd0:y+1'b1;end
     else begin nx<=x+1'b1;ny<=y;end
    end
   end
  end
 end
endmodule
