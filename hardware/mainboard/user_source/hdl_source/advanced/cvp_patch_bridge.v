// Two complete-patch banks. Main camera is independent of this ready/valid stream.
// A camera ROI producer checks ready at SOP, then sends exactly BYTES bytes.
module cvp_patch_bridge #(parameter WIDTH=32,HEIGHT=32,CHANNELS=1,PIXEL_FORMAT=0,BYTES=WIDTH*HEIGHT*CHANNELS,ADDR_W=$clog2(BYTES))(
 input clk,rst_n,i_valid,i_sop,i_eop,input [7:0] i_data,
 input [31:0] i_frame_id,input [15:0] i_roi_id,i_cfg_id,input [63:0] i_bbox,
 output i_ready,
 output reg o_valid,o_sop,o_eop,output [7:0] o_data,
 output [31:0] o_frame_id,output [15:0] o_roi_id,o_cfg_id,output [63:0] o_bbox,input o_ready,
 output [15:0] o_width,o_height,output [7:0] o_channels,o_format,
 output reg [31:0] dropped,output reg protocol_error
);
 reg [7:0] ram[0:2*BYTES-1],read_q;
 reg [1:0] complete;reg collecting,discard,wrbank,rdbank,issuing,last_issued;
 reg [ADDR_W-1:0] wp,rp;
 reg [127:0] desc[0:1];
 assign o_width=WIDTH;assign o_height=HEIGHT;assign o_channels=CHANNELS;assign o_format=PIXEL_FORMAT;
 assign i_ready=collecting||!complete[wrbank];
 assign o_data=read_q;
 assign {o_frame_id,o_roi_id,o_cfg_id,o_bbox}=desc[rdbank];
 wire accept=i_valid&&(collecting||i_sop);
 wire read_issue=issuing&&!last_issued&&(!o_valid||o_ready);
 always @(posedge clk)begin
  if(i_valid&&i_sop&&i_ready)ram[wrbank*BYTES]<=i_data;
  else if(accept&&collecting&&!discard)ram[wrbank*BYTES+wp]<=i_data;
  if(read_issue)read_q<=ram[rdbank*BYTES+rp];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   complete<=0;collecting<=0;discard<=0;wrbank<=0;rdbank<=0;issuing<=0;last_issued<=0;
   wp<=0;rp<=0;o_valid<=0;o_sop<=0;o_eop<=0;dropped<=0;protocol_error<=0;desc[0]<=0;desc[1]<=0;
  end else begin
   protocol_error<=0;
   if(i_valid&&i_ready)begin
    if(i_sop)begin
     if(collecting)begin protocol_error<=1;dropped<=dropped+1'b1;end
     collecting<=1;discard<=!i_ready;wp<=1;
     if(i_ready)desc[wrbank]<={i_frame_id,i_roi_id,i_cfg_id,i_bbox};
     else dropped<=dropped+1'b1;
    end else if(collecting)begin
     if(wp==BYTES-1)begin
      collecting<=0;
      if(!discard&&i_eop)begin complete[wrbank]<=1;wrbank<=~wrbank;end
      else if(!discard)begin dropped<=dropped+1'b1;protocol_error<=1;end
     end else wp<=wp+1'b1;
     if(i_eop&&wp!=BYTES-1)begin collecting<=0;protocol_error<=1;if(!discard)dropped<=dropped+1'b1;end
    end else if(i_eop)protocol_error<=1;
   end
   if(!issuing&&complete[rdbank])begin issuing<=1;rp<=0;last_issued<=0;end
   if(o_valid&&o_ready)begin
    o_valid<=0;
    if(o_eop)begin complete[rdbank]<=0;rdbank<=~rdbank;issuing<=0;last_issued<=0;end
   end
   if(read_issue)begin
    o_valid<=1;o_sop<=rp==0;o_eop<=rp==BYTES-1;
    if(rp==BYTES-1)last_issued<=1;else rp<=rp+1'b1;
   end
  end
 end
endmodule
