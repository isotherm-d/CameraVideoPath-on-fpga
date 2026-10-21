// Frame-atomic boxes and five-class text, baked into RGB before pack_4.
// Three pipeline cycles; metadata has exactly the same latency as RGB.
module cvp_cell_label #(parameter N=5,W=1280,H=720,MARGIN=16,DB_CNT=2000000,FULL_NAMES=0)(
 input clk,rst_n,input i_valid,i_sof,input [23:0] i_rgb,
 input [11:0] i_x,i_y,input [31:0] i_frame,input i_sw1_n,
 input [N*48-1:0] i_boxes,input [N*3-1:0] i_classes,input [N-1:0] i_known,
 output reg o_valid,o_sof,output reg [23:0] o_rgb,output reg [31:0] o_frame
);
 reg [1:0] sync;reg stable,en;reg [20:0] db;
 reg [11:0] bx0[0:N-1],by0[0:N-1],bx1[0:N-1],by1[0:N-1];
 reg [2:0] cls[0:N-1];reg [47:0] v;integer k;
 reg vi,si;reg [23:0] ri;reg [31:0] fi;reg [11:0] xi,yi;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin vi<=0;si<=0;ri<=0;fi<=0;xi<=0;yi<=0;end
  else begin vi<=i_valid;si<=i_sof;ri<=i_rgb;fi<=i_frame;xi<=i_x;yi<=i_y;end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   sync<=3;stable<=1;en<=1;db<=0;
   for(k=0;k<N;k=k+1)begin bx0[k]<=4095;by0[k]<=4095;bx1[k]<=0;by1[k]<=0;cls[k]<=5;end
  end else begin
   sync<={sync[0],i_sw1_n};
   if(sync[1]==stable)db<=0;
   else if(db==DB_CNT-1)begin db<=0;stable<=sync[1];if(!sync[1])en<=~en;end
   else db<=db+1'b1;
   if(i_valid&&i_sof)for(k=0;k<N;k=k+1)begin
    v=i_boxes[k*48+:48];
    if(v[47:36]<v[23:12] && v[35:24]<v[11:0] && v[23:12]<W && v[11:0]<H)begin
     bx0[k]<=v[47:36]>MARGIN?v[47:36]-MARGIN:0;
     by0[k]<=v[35:24]>MARGIN?v[35:24]-MARGIN:0;
     bx1[k]<=v[23:12]>=W-MARGIN?W-1:v[23:12]+MARGIN;
     by1[k]<=v[11:0]>=H-MARGIN?H-1:v[11:0]+MARGIN;
    end else begin bx0[k]<=4095;by0[k]<=4095;bx1[k]<=0;by1[k]<=0;end
    cls[k]<=i_known[k]?i_classes[k*3+:3]:3'd5;
   end
  end
 end
 localparam TEXT_W=FULL_NAMES?160:48;
 reg border,panel;reg [7:0] dx;reg [3:0] dy;reg [2:0] code;
 reg vb,sb,be,pe;reg [23:0] rgb;reg [31:0] frame;
 reg [7:0] tx;reg [3:0] ty;reg [2:0] tc;
 integer n;reg [11:0] lx,ly;
 always @* begin
  border=0;panel=0;dx=0;dy=0;code=5;lx=0;ly=0;
  for(n=N-1;n>=0;n=n-1)begin
   if(xi>=bx0[n]&&xi<=bx1[n]&&yi>=by0[n]&&yi<=by1[n]&&
    (xi-bx0[n]<12'd2||bx1[n]-xi<12'd2||yi-by0[n]<12'd2||by1[n]-yi<12'd2))border=1;
   // Anchor at the upper-left edge. At the screen top, inset into the
   // upper-left corner rather than moving the type below the cell.
   lx=by0[n]>=16?bx0[n]:bx0[n]+12'd2;
   if(lx>W-TEXT_W)lx=W-TEXT_W;
   ly=by0[n]>=16?by0[n]-12'd16:by0[n]+12'd2;
   if(ly>H-16)ly=H-16;
   if(cls[n]<6&&bx0[n]<=bx1[n]&&xi>=lx&&xi<lx+TEXT_W&&yi>=ly&&yi<ly+12'd16)begin
    panel=1;dx=xi-lx;dy=yi-ly;code=cls[n];
   end
  end
 end
 function [7:0] letter; input [2:0] c;input [1:0] pos;
  begin case(c)
   0:case(pos)0:letter="B";1:letter="A";2:letter="S";default:letter=" ";endcase
   1:case(pos)0:letter="E";1:letter="O";2:letter="S";default:letter=" ";endcase
   2:case(pos)0:letter="L";1:letter="Y";2:letter="M";default:letter=" ";endcase
   3:case(pos)0:letter="M";1:letter="O";2:letter="N";default:letter=" ";endcase
   4:case(pos)0:letter="N";1:letter="E";2:letter="U";default:letter=" ";endcase
   default:case(pos)0:letter="W";1:letter="A";2:letter="I";default:letter="T";endcase
  endcase end
 endfunction
 function [7:0] full_letter;input [2:0] c;input [3:0] pos;
  reg [79:0] text;
  begin case(c)
   0:text="Basophil  ";1:text="Eosinophil";2:text="Lymphocyte";
   3:text="Monocyte  ";4:text="Neutrophil";default:text="WAIT      ";
  endcase
   full_letter=pos<10?text[79-pos*8-:8]:8'd32;
  end
 endfunction
 function [34:0] glyph;input [7:0] ch;
  begin case(ch)
   "A":glyph=35'b01110_10001_10001_11111_10001_10001_10001;
   "B":glyph=35'b11110_10001_10001_11110_10001_10001_11110;
   "S":glyph=35'b01111_10000_10000_01110_00001_00001_11110;
   "E":glyph=35'b11111_10000_10000_11110_10000_10000_11111;
   "O":glyph=35'b01110_10001_10001_10001_10001_10001_01110;
   "L":glyph=35'b10000_10000_10000_10000_10000_10000_11111;
   "Y":glyph=35'b10001_10001_01010_00100_00100_00100_00100;
   "M":glyph=35'b10001_11011_10101_10101_10001_10001_10001;
   "N":glyph=35'b10001_11001_10101_10011_10001_10001_10001;
   "U":glyph=35'b10001_10001_10001_10001_10001_10001_01110;
   "W":glyph=35'b10001_10001_10001_10101_10101_11011_10001;
   "I":glyph=35'b01110_00100_00100_00100_00100_00100_01110;
   "T":glyph=35'b11111_00100_00100_00100_00100_00100_00100;
   "a":glyph=35'b00000_00000_01110_00001_01111_10001_01111;
   "c":glyph=35'b00000_00000_01111_10000_10000_10000_01111;
   "e":glyph=35'b00000_00000_01110_10001_11111_10000_01111;
   "h":glyph=35'b10000_10000_10110_11001_10001_10001_10001;
   "i":glyph=35'b00100_00000_01100_00100_00100_00100_01110;
   "l":glyph=35'b01100_00100_00100_00100_00100_00100_01110;
   "m":glyph=35'b00000_00000_11010_10101_10101_10101_10101;
   "n":glyph=35'b00000_00000_10110_11001_10001_10001_10001;
   "o":glyph=35'b00000_00000_01110_10001_10001_10001_01110;
   "p":glyph=35'b00000_11110_10001_10001_11110_10000_10000;
   "r":glyph=35'b00000_00000_10110_11001_10000_10000_10000;
   "s":glyph=35'b00000_00000_01111_10000_01110_00001_11110;
   "t":glyph=35'b00100_00100_11111_00100_00100_00100_00011;
   "u":glyph=35'b00000_00000_10001_10001_10001_10011_01101;
   "y":glyph=35'b00000_00000_10001_10001_01111_00001_01110;
   default:glyph=0;
  endcase end
 endfunction
 wire [3:0] cp=FULL_NAMES?tx[7:4]:(tx<12?0:tx<24?1:tx<36?2:3);
 wire [5:0] local_x=FULL_NAMES?{2'd0,tx[3:0]}:(tx<12?tx:tx<24?tx-12:tx<36?tx-24:tx-36);
 wire [34:0] bits35=glyph(FULL_NAMES?full_letter(tc,cp):letter(tc,cp[1:0]));
 wire ink=local_x[5:1]<5 && ty[3:1]<7 && bits35[34-(ty[3:1]*5+local_x[5:1])];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin vb<=0;sb<=0;be<=0;pe<=0;rgb<=0;frame<=0;tx<=0;ty<=0;tc<=5;
   o_valid<=0;o_sof<=0;o_rgb<=0;o_frame<=0;end
  else begin
   vb<=vi;sb<=si;rgb<=ri;frame<=fi;
   be<=border&&en;pe<=panel&&en;tx<=dx;ty<=dy;tc<=code;
   o_valid<=vb;o_sof<=sb;o_frame<=frame;
   o_rgb<=pe?(ink?(tc==5?24'hffff00:24'h00ffff):24'h000000):(be?24'h00ff00:rgb);
  end
 end
endmodule
