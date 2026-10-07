// Synchronous ERAM read with two output registers. Sustained one item/clock.
// The producer may stall only when o_ready=0. Camera callers count overflow.
module cvp_sync_fifo #(parameter DW=25, AW=11)(
 input clk,rst_n,input i_valid,input [DW-1:0] i_data,output o_ready,
 output o_valid,output [DW-1:0] o_data,input i_ready,output [AW:0] o_level
);
 localparam DEPTH=1<<AW;
 reg [DW-1:0] ram[0:DEPTH-1],ram_q,q0,q1;
 reg [AW-1:0] wp,rp; reg [AW:0] used;
 reg pending; reg [1:0] cached;
 wire pop=o_valid && i_ready, push=i_valid && o_ready;
 wire issue=(used!=0) && (cached+pending-pop<2);
 assign o_ready=used<DEPTH;
 assign o_valid=cached!=0;
 assign o_data=q0;
 assign o_level=used+cached+pending;
 always @(posedge clk) begin
  if(push)ram[wp]<=i_data;
  if(issue)ram_q<=ram[rp];
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin wp<=0;rp<=0;used<=0;pending<=0;cached<=0;q0<=0;q1<=0;end
  else begin
   if(push)wp<=wp+1'b1;
   if(issue)rp<=rp+1'b1;
   used<=used+push-issue; pending<=issue;
   cached<=cached+pending-pop;
   if(pop)q0<=q1;
   if(pending)begin
    if(cached-pop==0)q0<=ram_q;else q1<=ram_q;
   end
  end
 end
endmodule
