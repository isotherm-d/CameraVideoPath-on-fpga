// Bundled-data request/ack mailbox. Only one writer reaches sensor I2C.
// New requests while busy replace a pending request, never the in-flight data.
module cvp_sensor_bridge_v33_gold(
 input clk,rst_n,i_valid,input [15:0] i_exp,input [7:0] i_gain,
 output o_busy,output reg [15:0] o_exp,output reg [7:0] o_gain,
 output reg o_done,output reg o_error,
 input cfg_clk,cfg_rst_n,i_cfg_done,i_ae_done,i_iic_error,
 output reg o_req,output reg [15:0] o_cfg_exp,output reg [15:0] o_cfg_gain
);
 reg pending,outstanding,req_toggle,ack_toggle,ack1,ack2,ack_error;
 reg [15:0] queued_exp,held_exp;reg [7:0] queued_gain,held_gain;
 reg rq1,rq2,seen;reg [1:0] phase;reg [20:0] timeout;
 reg [15:0] exp1,exp2;reg [7:0] gain1,gain2;
 assign o_busy=pending||outstanding;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending<=1;outstanding<=0;req_toggle<=0;ack1<=0;ack2<=0;
   queued_exp<=500;queued_gain<=108;held_exp<=500;held_gain<=108;
   o_exp<=500;o_gain<=108;o_done<=0;o_error<=0;
  end else begin
   ack1<=ack_toggle;ack2<=ack1;o_done<=0;
   if(!outstanding&&pending)begin held_exp<=queued_exp;held_gain<=queued_gain;
    req_toggle<=~req_toggle;outstanding<=1;pending<=0;end
   if(outstanding&&ack2==req_toggle)begin
    outstanding<=0;o_done<=1;o_error<=ack_error;
    if(!ack_error)begin o_exp<=held_exp;o_gain<=held_gain;end
   end
   if(i_valid)begin queued_exp<=i_exp;queued_gain<=i_gain;pending<=1;end
  end
 end
 always @(posedge cfg_clk or negedge cfg_rst_n)begin
  if(!cfg_rst_n)begin
   rq1<=0;rq2<=0;seen<=0;ack_toggle<=0;ack_error<=0;phase<=0;timeout<=0;
   exp1<=500;exp2<=500;gain1<=108;gain2<=108;o_cfg_exp<=500;o_cfg_gain<=108;o_req<=0;
  end else begin
   rq1<=req_toggle;rq2<=rq1;exp1<=held_exp;exp2<=exp1;gain1<=held_gain;gain2<=gain1;o_req<=0;
   if(phase==0)begin
    if(rq2!=seen&&i_cfg_done&&i_ae_done)begin
     seen<=rq2;o_cfg_exp<=exp2;o_cfg_gain<=gain2;phase<=1;timeout<=0;
    end
   end else if(phase==1)begin o_req<=1;phase<=2;end
   else if(phase==2)begin
    timeout<=timeout+1'b1;
    if(!i_ae_done)phase<=3;
    else if(timeout==1200000)begin ack_error<=1;ack_toggle<=seen;phase<=0;end
   end else begin
    timeout<=timeout+1'b1;
    if(i_ae_done || timeout==1200000)begin ack_error<=i_iic_error||timeout==1200000;ack_toggle<=seen;phase<=0;end
   end
  end
 end
endmodule
