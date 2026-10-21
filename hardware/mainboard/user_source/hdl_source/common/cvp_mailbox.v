// Bundled-data CDC: source holds the entire snapshot until the receiver pops it.
module cvp_mailbox #(parameter DW=1024)(
 input s_clk,s_rst_n,s_valid,input [DW-1:0] s_data,output s_ready,
 input m_clk,m_rst_n,output m_valid,output reg [DW-1:0] m_data,input m_ready
);
 reg [DW-1:0] held;reg request,ack,a1,a2,r1,r2,received;
 assign s_ready=request==a2;assign m_valid=received!=ack;
 always @(posedge s_clk or negedge s_rst_n)begin
  if(!s_rst_n)begin held<=0;request<=0;a1<=0;a2<=0;end
  else begin a1<=ack;a2<=a1;if(s_valid&&s_ready)begin held<=s_data;request<=~request;end end
 end
 always @(posedge m_clk or negedge m_rst_n)begin
  if(!m_rst_n)begin r1<=0;r2<=0;received<=0;ack<=0;m_data<=0;end
  else begin
   r1<=request;r2<=r1;
   if(r2!=received && received==ack)begin m_data<=held;received<=r2;end
   if(m_valid&&m_ready)ack<=received;
  end
 end
endmodule
