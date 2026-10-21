// Unsigned (numerator<<8)/denominator. Inputs latched; no DSP.
module cvp_divider(input clk,rst_n,start,input [31:0] numerator,denominator,
 output reg done,output reg [31:0] quotient);
 reg [39:0] bits,q;reg [32:0] rem;reg [31:0] den;reg [5:0] left;reg busy;
 wire [32:0] shift={rem[31:0],bits[39]};
 wire ge=shift>={1'b0,den};wire [32:0] nr=ge?shift-{1'b0,den}:shift;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;done<=0;quotient<=0;bits<=0;q<=0;rem<=0;den<=1;left<=0;end
  else begin
   done<=0;
   if(start&&!busy)begin
    if(denominator==0)begin quotient<=0;done<=1;end
    else begin bits<={numerator,8'd0};q<=0;rem<=0;den<=denominator;left<=39;busy<=1;end
   end else if(busy)begin
    bits<={bits[38:0],1'b0};rem<=nr;q<={q[38:0],ge};
    if(left==0)begin quotient<=|q[38:31]?32'hffffffff:{q[30:0],ge};done<=1;busy<=0;end
    else left<=left-1'b1;
   end
  end
 end
endmodule
