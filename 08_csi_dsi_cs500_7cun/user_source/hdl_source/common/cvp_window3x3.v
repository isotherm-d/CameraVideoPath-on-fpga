// Centred W*H image, with complete right/bottom drain and explicit coordinates.
// RGB uses replicate padding; Bayer RAW uses reflection to preserve colour phase.
// Real-time camera input: <=80% sustained valid duty, plus normal frame blanking.
// A bounded FIFO absorbs the W+1-cycle bottom drain. No input backpressure.
module cvp_window3x3 #(parameter W=1280,H=720,DW=24,BAYER_PAD=0,FIFO_AW=11)(
 input clk,rst_n,i_valid,input [DW-1:0] i_data,input i_sof,
 output o_valid,o_sof,o_eol,o_eof,output [11:0] o_x,o_y,
 output [DW-1:0] p00,p01,p02,p10,p11,p12,p20,p21,p22,
 output reg o_overflow
);
 wire q_valid,q_ready;wire [DW:0] q;
 reg [1:0] state;localparam NORMAL=0,DRAIN=1,TAIL=2,WAIT_LAST=3;
 reg [11:0] nx,ny,flush_x;
 wire consume=q_valid && state==NORMAL;
 cvp_sync_fifo #(.DW(DW+1),.AW(FIFO_AW)) queue(
  .clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_data({i_sof,i_data}),
  .o_ready(q_ready),.o_valid(q_valid),.o_data(q),.i_ready(state==NORMAL),.o_level());
 wire token=consume || state==DRAIN || state==TAIL;
 wire drain=state!=NORMAL;
 wire [11:0] tx=state==DRAIN?flush_x:state==TAIL?12'd0:q[DW]?12'd0:nx;
 wire [11:0] ty=state==DRAIN?H:state==TAIL?H+1:q[DW]?12'd0:ny;
 reg [DW-1:0] line1[0:W-1],line2[0:W-1],rd1,rd2;
 reg [DW-1:0] c1,c2,prev2;
 reg v1,v2,d1,d2;reg [11:0] x1,x2,y1,y2;
 always @(posedge clk)begin
  if(token)begin rd1<=line1[tx];if(!drain)line1[tx]<=q[DW-1:0];end
  if(v1)begin rd2<=line2[x1];if(!d1)line2[x1]<=rd1;end
 end
 wire [DW-1:0] bottom=d2 ? (BAYER_PAD ? rd2:prev2):c2;
 wire [DW-1:0] top=y2==1?(BAYER_PAD?bottom:prev2):rd2;
 wire [DW-1:0] mid=prev2;
 reg [DW-1:0] a0,b0,a1,b1,a2,b2;
 wire right_tail=x2==0;
 wire reflect_left=BAYER_PAD && x2==1;
 assign o_valid=v2 && ((x2!=0 && y2>=1)||(x2==0 && y2>=2));
 assign o_x=right_tail?W-1:x2-1'b1;
 assign o_y=right_tail?y2-2:y2-1'b1;
 assign o_sof=o_valid && o_x==0 && o_y==0;
 assign o_eol=o_valid && o_x==W-1;
 assign o_eof=o_eol && o_y==H-1;
 assign p00=right_tail?b0:reflect_left?top:x2==1?a0:b0;
 assign p01=a0;assign p02=right_tail?(BAYER_PAD?b0:a0):top;
 assign p10=right_tail?b1:reflect_left?mid:x2==1?a1:b1;
 assign p11=a1;assign p12=right_tail?(BAYER_PAD?b1:a1):mid;
 assign p20=right_tail?b2:reflect_left?bottom:x2==1?a2:b2;
 assign p21=a2;assign p22=right_tail?(BAYER_PAD?b2:a2):bottom;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=NORMAL;nx<=0;ny<=0;flush_x<=0;o_overflow<=0;
   v1<=0;v2<=0;d1<=0;d2<=0;x1<=0;y1<=0;x2<=0;y2<=0;
   c1<=0;c2<=0;prev2<=0;a0<=0;b0<=0;a1<=0;b1<=0;a2<=0;b2<=0;
  end else begin
   o_overflow<=i_valid&&!q_ready;
   v1<=token;v2<=v1;
   if(token)begin x1<=tx;y1<=ty;d1<=drain;c1<=q[DW-1:0];end
   if(v1)begin x2<=x1;y2<=y1;d2<=d1;c2<=c1;prev2<=rd1;end
   if(v2)begin a0<=top;b0<=a0;a1<=mid;b1<=a1;a2<=bottom;b2<=a2;end
   if(consume)begin
    if(tx==W-1)begin nx<=0;ny<=ty+1'b1;end else begin nx<=tx+1'b1;ny<=ty;end
    if(tx==W-1 && ty==H-1)begin state<=DRAIN;flush_x<=0;end
   end else if(state==DRAIN)begin
    if(flush_x==W-1)state<=TAIL;else flush_x<=flush_x+1'b1;
   end else if(state==TAIL)state<=WAIT_LAST;
   else if(state==WAIT_LAST && o_eof)begin state<=NORMAL;nx<=0;ny<=0;end
  end
 end
endmodule
