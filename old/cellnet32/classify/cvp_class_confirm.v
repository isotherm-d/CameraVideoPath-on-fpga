// A single fixed field has a single class history, independent of detector IDs.
module cvp_class_confirm #(parameter TTL=15,INIT_HITS=2,SWITCH_HITS=3)(
 input clk,rst_n,input i_result,input [2:0] i_class,input [31:0] i_capture_frame,i_frame,
 input [15:0] i_cfg,i_result_cfg,output [2:0] o_class,output o_known
);
 reg seen,known;reg [2:0] klass,challenger,votes;
 reg [31:0] last_frame;reg [15:0] last_cfg;
 wire [31:0] delta=i_capture_frame-last_frame;
 wire fresh=seen && last_cfg==i_cfg && i_frame-last_frame<=TTL;
 assign o_class=klass;
 assign o_known=known && fresh;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin seen<=0;known<=0;klass<=0;challenger<=0;votes<=0;last_frame<=0;last_cfg<=0;end
  else if(i_result && i_class<5 && i_result_cfg==i_cfg && i_frame-i_capture_frame<=TTL &&
           (!seen || last_cfg!=i_cfg || (delta!=0 && !delta[31])))begin
   seen<=1;last_frame<=i_capture_frame;last_cfg<=i_result_cfg;
   if(!known || !fresh)begin
    known<=0;
    if(INIT_HITS<=1 || (fresh && votes!=0 && challenger==i_class && votes>=INIT_HITS-1))begin
     known<=1;klass<=i_class;votes<=0;
    end else if(fresh && votes!=0 && challenger==i_class)votes<=votes+1'b1;
    else begin challenger<=i_class;votes<=1;end
   end else if(i_class==klass)begin votes<=0;challenger<=i_class;end
   else if(SWITCH_HITS<=1 || (votes!=0 && challenger==i_class && votes>=SWITCH_HITS-1))begin
    klass<=i_class;votes<=0;
   end else if(votes!=0 && challenger==i_class)votes<=votes+1'b1;
   else begin challenger<=i_class;votes<=1;end
  end
 end
endmodule
