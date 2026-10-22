module cvp_keys #(parameter DEBOUNCE=2000000)(
 input clk,rst_n,input [1:0] keys_n,output reg next,prev
);
 reg [1:0] s0,s1,stable;reg [21:0] count0,count1;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin s0<=3;s1<=3;stable<=3;count0<=0;count1<=0;next<=0;prev<=0;end
  else begin
   s0<=keys_n;s1<=s0;next<=0;prev<=0;
   // Board KEY2 is keys_n[0] (previous); KEY3 is keys_n[1] (next).
   if(s1[0]==stable[0])count0<=0;else if(count0==DEBOUNCE-1)begin count0<=0;stable[0]<=s1[0];prev<=!s1[0];end else count0<=count0+1'b1;
   if(s1[1]==stable[1])count1<=0;else if(count1==DEBOUNCE-1)begin count1<=0;stable[1]<=s1[1];next<=!s1[1];end else count1<=count1+1'b1;
  end
 end
endmodule
