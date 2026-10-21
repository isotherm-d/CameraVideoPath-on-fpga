// Discard startup/partial frames. Once started, AE writes never stop video.
module cvp_camera_gate(
 input clk,rst_n,i_cfg_done,i_ae_done,i_valid,i_sof,
 output o_valid,output o_sof
);
 reg ready1,ready2,started;
 wire accept=i_valid&&(started||(ready2&&i_sof));
 assign o_valid=accept;assign o_sof=accept&&i_sof;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin ready1<=0;ready2<=0;started<=0;end
  else begin ready1<=i_cfg_done&&i_ae_done;ready2<=ready1;if(accept&&i_sof)started<=1;end
 end
endmodule
