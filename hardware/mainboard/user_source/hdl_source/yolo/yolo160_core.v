// Folded layers 1..9. Four output lanes share one input activation per cycle.
// W4 hidden / W8 head, A4, signed24 accumulator; all buffers are synchronous.
`include "yolo160_config.vh"
module yolo160_core #(
 parameter W4FILE="../../../user_source/hdl_source/yolo/model/weights4.hex",
 parameter HFILE="../../../user_source/hdl_source/yolo/model/head8.hex",
 parameter MFILE="../../../user_source/hdl_source/yolo/model/meta.hex"
)(
 input clk,rst_n,input i_we,input [12:0] i_addr,input [31:0] i_data,
 input i_start,i_abort,output reg busy,done,
 output reg logit_valid,output reg [3:0] logit_x,logit_y,
 output reg [4:0] logit_channel,output reg signed [15:0] logit,
 output reg layer_done,output reg [3:0] layer
);
 reg [31:0] p0[0:6399],p1[0:1599];
 reg [31:0] wrom[0:`YOLO_W4_WORDS-1];
 reg [63:0] hrom[0:`YOLO_HEAD_WORDS-1];
 reg [39:0] mrom[0:`YOLO_META_WORDS-1];
 initial begin $readmemh(W4FILE,wrom);$readmemh(HFILE,hrom);$readmemh(MFILE,mrom);end
 reg [31:0] q0,q1,wq;reg [63:0] hq;reg [39:0] mq;
 reg [8:0] maddr;reg [12:0] input_addr;
 reg [13:0] weight_group_base;reg [9:0] step,nsteps;
 wire [13:0] weight_addr=weight_group_base+step;
 reg [6:0] dim,cin,cout,odim;reg [3:0] ng,ig;
 reg [10:0] rw;reg pool_en,kernel_one;
 reg [13:0] weight_base;reg [8:0] meta_base;
 reg [5:0] state;reg [6:0] ox,oy,pixx,pixy;
 reg half;reg [15:0] partial_low,qhalf,poolhalf,pooledhalf;
 reg [3:0] group;reg [2:0] mlane,emit_lane;
 reg [1:0] sub,ky,kx;reg [6:0] ic;
 reg [16:0] base_row,base_col,base_pixel;
 reg [12:0] outptr;reg [31:0] quant_word,poolmax,pooled;
 reg [63:0] head_word;
 reg signed [23:0] bias[0:3],acc[0:3];reg [4:0] shift[0:3];
 reg vread,fread,lread,zero_read;reg [2:0] nibble_read;
 reg vact,fact,lact,vmul,fmul,lmul;reg signed [12:0] prod[0:3];reg ended;
 wire signed [9:0] iy=$signed({3'b0,pixy})+(kernel_one?0:$signed({8'b0,ky})-1);
 wire signed [9:0] ix=$signed({3'b0,pixx})+(kernel_one?0:$signed({8'b0,kx})-1);
 wire outside=ix<0 || iy<0 || ix>=dim || iy>=dim;
 wire signed [17:0] rowoff=kernel_one?18'sd0:(ky==0?-$signed({7'b0,rw}):ky==1?18'sd0:$signed({7'b0,rw}));
 wire signed [17:0] coloff=kernel_one?18'sd0:(kx==0?-$signed({14'b0,ig}):kx==1?18'sd0:$signed({14'b0,ig}));
 wire signed [17:0] effective=$signed({1'b0,base_pixel})+rowoff+coloff+{14'b0,ic[6:3]};
 wire [12:0] ra=outside?13'd0:effective[12:0];
 wire [31:0] source_word=layer[0]?q0:q1;
 wire c1_write=i_we && !busy;
 wire feature_write=state==10 && layer!=9;
 wire [12:0] p0wa=c1_write?i_addr:outptr;
 wire [31:0] feature_data=pool_en?pooled:quant_word;
 wire [31:0] p0wd=c1_write?i_data:feature_data;
 wire [3:0] activation=zero_read?4'd0:(source_word>>(nibble_read*4));
 function signed [12:0] lut_mul;
  input [3:0] a;input signed [7:0] b;
  reg signed [12:0] t,p0,p1,p2,p3,s0,s1;
  begin t=b;p0=a[0]?t:0;p1=a[1]?(t<<<1):0;
   p2=a[2]?(t<<<2):0;p3=a[3]?(t<<<3):0;
   s0=p0+p1;s1=p2+p3;lut_mul=s0+s1;end
 endfunction
 function signed [31:0] rq;
  input signed [23:0] a,b;input [4:0] s;
  reg signed [23:0] v;
  begin v=a+b+(s?(24'sd1<<<(s-1)):0);rq=v>>>s;end
 endfunction
 function [3:0] sat4;
  input signed [31:0] v;
  begin sat4=v<0?0:v>15?15:v[3:0];end
 endfunction
 function [15:0] sat16;
  input signed [31:0] v;
  begin sat16=v< -32768?16'h8000:v>32767?16'h7fff:v[15:0];end
 endfunction
 always @*begin
  pooledhalf=0;
  for(integer k=0;k<4;k=k+1)pooledhalf[k*4+:4]=poolhalf[k*4+:4]>qhalf[k*4+:4]?poolhalf[k*4+:4]:qhalf[k*4+:4];
  pooled=quant_word;
 end
 always @(posedge clk)begin
  if(c1_write || (feature_write && !layer[0]))p0[p0wa]<=p0wd;
  q0<=p0[ra];q1<=p1[ra<1600?ra:0];
  wq<=wrom[weight_addr<`YOLO_W4_WORDS?weight_addr:0];
  hq<=hrom[weight_addr<`YOLO_HEAD_WORDS?weight_addr:0];mq<=mrom[maddr];
  if(feature_write && layer[0])p1[outptr]<=feature_data;
 end
 genvar g;
 generate for(g=0;g<4;g=g+1)begin:P
  wire [31:0] hh=half?hq[63:32]:hq[31:0];
  wire [15:0] wh=half?wq[31:16]:wq[15:0];
  wire signed [7:0] wt=layer==9?$signed(hh[g*8+:8]):$signed({{4{wh[g*4+3]}},wh[g*4+:4]});
  reg [3:0] aq;reg signed [7:0] wreg;
  always @(posedge clk)begin aq<=activation;wreg<=wt;prod[g]<=lut_mul(aq,wreg);end
 end endgenerate
 integer j;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin vread<=0;fread<=0;lread<=0;zero_read<=0;nibble_read<=0;
   vact<=0;fact<=0;lact<=0;vmul<=0;fmul<=0;lmul<=0;ended<=0;for(j=0;j<4;j=j+1)acc[j]<=0;
  end else begin
   vread<=state==6;fread<=step==0;lread<=step==nsteps-1;zero_read<=outside;nibble_read<=ic[2:0];
   vact<=vread;fact<=fread;lact<=lread;vmul<=vact;fmul<=fact;lmul<=lact;ended<=0;
   if(vmul)begin
    for(j=0;j<4;j=j+1)acc[j]<=fmul?$signed(prod[j]):acc[j]+$signed(prod[j]);
    if(lmul)ended<=1;
   end
   if(i_abort)begin vread<=0;vact<=0;vmul<=0;ended<=0;end
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=0;busy<=0;done<=0;layer<=0;layer_done<=0;logit_valid<=0;logit<=0;
   logit_x<=0;logit_y<=0;logit_channel<=0;dim<=0;cin<=0;cout<=0;odim<=0;ng<=0;ig<=0;rw<=0;
   pool_en<=0;kernel_one<=0;weight_base<=0;meta_base<=0;weight_group_base<=0;maddr<=0;
   ox<=0;oy<=0;pixx<=0;pixy<=0;group<=0;mlane<=0;emit_lane<=0;sub<=0;ky<=0;kx<=0;ic<=0;
   base_row<=0;base_col<=0;base_pixel<=0;outptr<=0;quant_word<=0;poolmax<=0;head_word<=0;half<=0;partial_low<=0;qhalf<=0;poolhalf<=0;step<=0;nsteps<=0;
   for(j=0;j<4;j=j+1)begin bias[j]<=0;shift[j]<=0;end
  end else begin
   done<=0;layer_done<=0;logit_valid<=0;
   case(state)
    0:if(i_start)begin busy<=1;layer<=1;state<=1;end
    1:begin
     case(layer)
      `include "yolo160_layers.vh"
      default:begin dim<=10;cin<=40;cout<=18;ng<=3;ig<=5;rw<=50;odim<=10;pool_en<=0;kernel_one<=0;weight_base<=0;meta_base<=248;end
     endcase
     state<=2;
    end
    2:begin
     ox<=0;oy<=0;group<=0;half<=0;poolhalf<=0;sub<=0;outptr<=0;base_row<=0;base_col<=0;poolmax<=0;
     nsteps<=kernel_one?{3'b0,cin}:({3'b0,cin}<<3)+cin;
     weight_group_base<=layer==9?0:weight_base;mlane<=0;maddr<=meta_base;state<=3;
    end
    3:state<=4;
    4:begin
     bias[mlane]<=mq[23:0];shift[mlane]<=mq[36:32];
     if(mlane==3)state<=5;
     else begin mlane<=mlane+1'b1;maddr<=maddr+1'b1;state<=3;end
    end
    5:begin
     base_pixel<=base_row+base_col+(pool_en && sub[1]?rw:0)+(pool_en && sub[0]?ig:0);
     pixx<=(pool_en?(ox<<1):ox)+(pool_en?sub[0]:0);
     pixy<=(pool_en?(oy<<1):oy)+(pool_en?sub[1]:0);
     step<=0;ky<=0;kx<=0;ic<=0;state<=6;
    end
    6:begin
     if(step==nsteps-1)state<=7;
     else begin
      step<=step+1'b1;
      if(ic==cin-1)begin ic<=0;if(kx==2)begin kx<=0;ky<=ky+1'b1;end else kx<=kx+1'b1;end
      else ic<=ic+1'b1;
     end
    end
    7:if(ended)state<=8;
    8:begin
     for(j=0;j<4;j=j+1)begin
      qhalf[j*4+:4]<=sat4(rq(acc[j],bias[j],shift[j]));
      head_word[j*16+:16]<=sat16(rq(acc[j],bias[j],shift[j]));
     end
     state<=9;
    end
    9:begin
     if(layer==9)begin emit_lane<=0;state<=12;end
     else if(pool_en && sub!=3)begin poolhalf<=sub==0?qhalf:pooledhalf;sub<=sub+1'b1;state<=5;end
     else if(!half)begin partial_low<=pool_en?pooledhalf:qhalf;state<=13;end
     else begin quant_word<={pool_en?pooledhalf:qhalf,partial_low};state<=10;end
    end
    10:state<=11;
    11:begin
     outptr<=outptr+1'b1;sub<=0;poolmax<=0;poolhalf<=0;half<=0;mlane<=0;
     if(group!=ng-1)begin
      group<=group+1'b1;weight_group_base<=weight_group_base+nsteps;
      maddr<=meta_base+((group+1'b1)<<3);state<=3;
     end else begin
      group<=0;weight_group_base<=layer==9?0:weight_base;maddr<=meta_base;
      if(ox!=odim-1)begin ox<=ox+1'b1;base_col<=base_col+(pool_en?(ig<<1):ig);state<=3;end
      else if(oy!=odim-1)begin ox<=0;oy<=oy+1'b1;base_col<=0;base_row<=base_row+(pool_en?(rw<<1):rw);state<=3;end
      else begin layer_done<=1;
       if(layer==9)begin done<=1;busy<=0;state<=0;end
       else begin layer<=layer+1'b1;state<=1;end
      end
     end
    end
    12:begin
     if((group<<3)+(half?4:0)+emit_lane<cout)begin
      logit_valid<=1;logit_x<=ox[3:0];logit_y<=oy[3:0];logit_channel<=(group<<3)+(half?4:0)+emit_lane;
      logit<=head_word[emit_lane*16+:16];
     end
     if(emit_lane==3)state<=half?11:13;else emit_lane<=emit_lane+1'b1;
    end
    13:begin half<=1;sub<=0;poolhalf<=0;mlane<=0;maddr<=meta_base+(group<<3)+4;state<=3;end
    default:state<=0;
   endcase
   if(i_abort)begin busy<=0;state<=0;logit_valid<=0;done<=0;end
  end
 end
endmodule
