// All fields advance with exactly the same clock latency, including bubbles.
module cvp_pixel_delay #(parameter LATENCY=1)(
 input clk,rst_n,i_valid,input [127:0] i_pixel,
 output o_valid,output [127:0] o_pixel
);
 generate if(LATENCY==0)begin
  assign o_valid=i_valid;assign o_pixel=i_pixel;
 end else begin
  reg [LATENCY-1:0] v;reg [127:0] data[0:LATENCY-1];integer k;
  assign o_valid=v[LATENCY-1];assign o_pixel=data[LATENCY-1];
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin v<=0;for(k=0;k<LATENCY;k=k+1)data[k]<=0;end
   else begin
    v[0]<=i_valid;data[0]<=i_pixel;
    for(k=1;k<LATENCY;k=k+1)begin v[k]<=v[k-1];data[k]<=data[k-1];end
   end
  end
 end endgenerate
endmodule
