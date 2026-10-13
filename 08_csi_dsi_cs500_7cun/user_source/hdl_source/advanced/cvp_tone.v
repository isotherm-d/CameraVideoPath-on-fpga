// Optional display-only auto levels. Coefficients apply atomically at SOF.
module cvp_tone(
 input clk,rst_n,i_valid,i_sof,input [23:0] i_rgb,input i_en,
 input i_stats_done,input [7:0] i_black,i_white,
 output reg o_valid,o_sof,output reg [23:0] o_rgb
);
 reg [10:0] pending_gain,active_gain;reg signed [11:0] pending_offset,active_offset;
 reg start;reg [7:0] span;
 reg busy,done;reg [5:0] left;reg [10:0] lookup_held,limited;
 reg [7:0] black;
 // Exact clamp(floor((224<<8)/span),128,512). No run-time divider.
 function [10:0] gain_for_span;input [7:0] d;begin
  case(d)
   8'd112:gain_for_span=11'd512;
   8'd113:gain_for_span=11'd507;
   8'd114:gain_for_span=11'd503;
   8'd115:gain_for_span=11'd498;
   8'd116:gain_for_span=11'd494;
   8'd117:gain_for_span=11'd490;
   8'd118:gain_for_span=11'd485;
   8'd119:gain_for_span=11'd481;
   8'd120:gain_for_span=11'd477;
   8'd121:gain_for_span=11'd473;
   8'd122:gain_for_span=11'd470;
   8'd123:gain_for_span=11'd466;
   8'd124:gain_for_span=11'd462;
   8'd125:gain_for_span=11'd458;
   8'd126:gain_for_span=11'd455;
   8'd127:gain_for_span=11'd451;
   8'd128:gain_for_span=11'd448;
   8'd129:gain_for_span=11'd444;
   8'd130:gain_for_span=11'd441;
   8'd131:gain_for_span=11'd437;
   8'd132:gain_for_span=11'd434;
   8'd133:gain_for_span=11'd431;
   8'd134:gain_for_span=11'd427;
   8'd135:gain_for_span=11'd424;
   8'd136:gain_for_span=11'd421;
   8'd137:gain_for_span=11'd418;
   8'd138:gain_for_span=11'd415;
   8'd139:gain_for_span=11'd412;
   8'd140:gain_for_span=11'd409;
   8'd141:gain_for_span=11'd406;
   8'd142:gain_for_span=11'd403;
   8'd143:gain_for_span=11'd401;
   8'd144:gain_for_span=11'd398;
   8'd145:gain_for_span=11'd395;
   8'd146:gain_for_span=11'd392;
   8'd147:gain_for_span=11'd390;
   8'd148:gain_for_span=11'd387;
   8'd149:gain_for_span=11'd384;
   8'd150:gain_for_span=11'd382;
   8'd151:gain_for_span=11'd379;
   8'd152:gain_for_span=11'd377;
   8'd153:gain_for_span=11'd374;
   8'd154:gain_for_span=11'd372;
   8'd155:gain_for_span=11'd369;
   8'd156:gain_for_span=11'd367;
   8'd157:gain_for_span=11'd365;
   8'd158:gain_for_span=11'd362;
   8'd159:gain_for_span=11'd360;
   8'd160:gain_for_span=11'd358;
   8'd161:gain_for_span=11'd356;
   8'd162:gain_for_span=11'd353;
   8'd163:gain_for_span=11'd351;
   8'd164:gain_for_span=11'd349;
   8'd165:gain_for_span=11'd347;
   8'd166:gain_for_span=11'd345;
   8'd167:gain_for_span=11'd343;
   8'd168:gain_for_span=11'd341;
   8'd169:gain_for_span=11'd339;
   8'd170:gain_for_span=11'd337;
   8'd171:gain_for_span=11'd335;
   8'd172:gain_for_span=11'd333;
   8'd173:gain_for_span=11'd331;
   8'd174:gain_for_span=11'd329;
   8'd175:gain_for_span=11'd327;
   8'd176:gain_for_span=11'd325;
   8'd177:gain_for_span=11'd323;
   8'd178:gain_for_span=11'd322;
   8'd179:gain_for_span=11'd320;
   8'd180:gain_for_span=11'd318;
   8'd181:gain_for_span=11'd316;
   8'd182:gain_for_span=11'd315;
   8'd183:gain_for_span=11'd313;
   8'd184:gain_for_span=11'd311;
   8'd185:gain_for_span=11'd309;
   8'd186:gain_for_span=11'd308;
   8'd187:gain_for_span=11'd306;
   8'd188:gain_for_span=11'd305;
   8'd189:gain_for_span=11'd303;
   8'd190:gain_for_span=11'd301;
   8'd191:gain_for_span=11'd300;
   8'd192:gain_for_span=11'd298;
   8'd193:gain_for_span=11'd297;
   8'd194:gain_for_span=11'd295;
   8'd195:gain_for_span=11'd294;
   8'd196:gain_for_span=11'd292;
   8'd197:gain_for_span=11'd291;
   8'd198:gain_for_span=11'd289;
   8'd199:gain_for_span=11'd288;
   8'd200:gain_for_span=11'd286;
   8'd201:gain_for_span=11'd285;
   8'd202:gain_for_span=11'd283;
   8'd203:gain_for_span=11'd282;
   8'd204:gain_for_span=11'd281;
   8'd205:gain_for_span=11'd279;
   8'd206:gain_for_span=11'd278;
   8'd207:gain_for_span=11'd277;
   8'd208:gain_for_span=11'd275;
   8'd209:gain_for_span=11'd274;
   8'd210:gain_for_span=11'd273;
   8'd211:gain_for_span=11'd271;
   8'd212:gain_for_span=11'd270;
   8'd213:gain_for_span=11'd269;
   8'd214:gain_for_span=11'd267;
   8'd215:gain_for_span=11'd266;
   8'd216:gain_for_span=11'd265;
   8'd217:gain_for_span=11'd264;
   8'd218:gain_for_span=11'd263;
   8'd219:gain_for_span=11'd261;
   8'd220:gain_for_span=11'd260;
   8'd221:gain_for_span=11'd259;
   8'd222:gain_for_span=11'd258;
   8'd223:gain_for_span=11'd257;
   8'd224:gain_for_span=11'd256;
   8'd225:gain_for_span=11'd254;
   8'd226:gain_for_span=11'd253;
   8'd227:gain_for_span=11'd252;
   8'd228:gain_for_span=11'd251;
   8'd229:gain_for_span=11'd250;
   8'd230:gain_for_span=11'd249;
   8'd231:gain_for_span=11'd248;
   8'd232:gain_for_span=11'd247;
   8'd233:gain_for_span=11'd246;
   8'd234:gain_for_span=11'd245;
   8'd235:gain_for_span=11'd244;
   8'd236:gain_for_span=11'd242;
   8'd237:gain_for_span=11'd241;
   8'd238:gain_for_span=11'd240;
   8'd239:gain_for_span=11'd239;
   8'd240:gain_for_span=11'd238;
   8'd241:gain_for_span=11'd237;
   8'd242:gain_for_span=11'd236;
   8'd243:gain_for_span=11'd235;
   8'd244:gain_for_span=11'd235;
   8'd245:gain_for_span=11'd234;
   8'd246:gain_for_span=11'd233;
   8'd247:gain_for_span=11'd232;
   8'd248:gain_for_span=11'd231;
   8'd249:gain_for_span=11'd230;
   8'd250:gain_for_span=11'd229;
   8'd251:gain_for_span=11'd228;
   8'd252:gain_for_span=11'd227;
   8'd253:gain_for_span=11'd226;
   8'd254:gain_for_span=11'd225;
   8'd255:gain_for_span=11'd224;
   default:gain_for_span=d==0?11'd128:11'd512;
  endcase
 end endfunction
 // The legacy divider captures start, runs 40 iterations, then pulses done.
 // Keeping that latency preserves SOF updates even for very short frames.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;done<=0;left<=0;lookup_held<=0;limited<=128;end
  else begin
   done<=0;
   if(start&&!busy)begin lookup_held<=gain_for_span(span);left<=39;busy<=1;end
   else if(busy)begin
    if(left==0)begin limited<=lookup_held;done<=1;busy<=0;end
    else left<=left-1'b1;
   end
  end
 end
 wire [18:0] black_product=black*limited;
 wire [10:0] gain=i_sof?(i_en?pending_gain:11'd256):active_gain;
 wire signed [11:0] offset=i_sof?(i_en?pending_offset:12'sd0):active_offset;
 function [7:0] map;input [7:0] p;input [10:0] g;input signed [11:0] off;
 reg [19:0] prod;reg signed [20:0] z;begin
 prod=p*g+128;z=$signed({1'b0,prod[19:8]})+off;
 map=z<0?0:z>255?255:z[7:0];end endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin pending_gain<=256;active_gain<=256;pending_offset<=0;active_offset<=0;
   start<=0;span<=224;black<=0;o_valid<=0;o_sof<=0;o_rgb<=0;end
  else begin
   start<=0;
   if(i_stats_done)begin
    if(i_white>i_black+24)begin span<=i_white-i_black;black<=i_black;start<=1;end
    else begin pending_gain<=256;pending_offset<=0;end
   end
   if(done)begin pending_gain<=limited;pending_offset<=12'sd16-$signed({1'b0,black_product[18:8]});end
   if(i_valid&&i_sof)begin active_gain<=gain;active_offset<=offset;end
   o_valid<=i_valid;o_sof<=i_valid&&i_sof;
   o_rgb<={map(i_rgb[23:16],gain,offset),map(i_rgb[15:8],gain,offset),map(i_rgb[7:0],gain,offset)};
  end
 end
endmodule
