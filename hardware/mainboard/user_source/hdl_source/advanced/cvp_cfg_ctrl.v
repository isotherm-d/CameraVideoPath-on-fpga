module cvp_cfg_ctrl #(parameter MODE_COUNT=7)(
 input clk,rst_n,i_sof,i_next,i_prev,
 input i_valid,input [15:0] i_req_id,i_cfg_id,input [7:0] i_op,i_addr,input [31:0] i_value,
 input i_legacy_valid,input [7:0] i_legacy_cmd,input [23:0] i_legacy_value,
 input [63:0] i_ticks,
 output wire [7:0] o_mode,
 output wire [0:0] o_ae_en,
 output wire [1:0] o_wb_mode,
 output wire [15:0] o_exposure,
 output wire [7:0] o_gain,
 output wire [6:0] o_kelvin,
 output wire [10:0] o_gain_r,
 output wire [10:0] o_gain_g,
 output wire [10:0] o_gain_b,
 output wire [0:0] o_swap,
 output wire [0:0] o_tone,
 output wire [0:0] o_osd,
 output wire [7:0] o_binary,
 output wire [10:0] o_edge_low,
 output wire [10:0] o_edge_high,
 output wire [10:0] o_sketch_low,
 output wire [10:0] o_sketch_high,
 output wire [1:0] o_edge_width,
 output wire [1:0] o_sketch_width,
 output wire [15:0] o_cfg_id,
 output reg o_sensor_valid,output reg [15:0] o_sensor_exp,output reg [7:0] o_sensor_gain,
 output reg o_reply_valid,output reg [15:0] o_reply_req,o_reply_cfg,
 output reg [7:0] o_reply_status,output reg [31:0] o_reply_value,
 output reg [63:0] o_sync_rx_tick,output reg [15:0] o_sync_id
);
 reg [7:0] s_mode,a_mode;
 reg [0:0] s_ae_en,a_ae_en;
 reg [1:0] s_wb_mode,a_wb_mode;
 reg [15:0] s_exposure,a_exposure;
 reg [7:0] s_gain,a_gain;
 reg [6:0] s_kelvin,a_kelvin;
 reg [10:0] s_gain_r,a_gain_r;
 reg [10:0] s_gain_g,a_gain_g;
 reg [10:0] s_gain_b,a_gain_b;
 reg [0:0] s_swap,a_swap;
 reg [0:0] s_tone,a_tone;
 reg [0:0] s_osd,a_osd;
 reg [7:0] s_binary,a_binary;
 reg [10:0] s_edge_low,a_edge_low;
 reg [10:0] s_edge_high,a_edge_high;
 reg [10:0] s_sketch_low,a_sketch_low;
 reg [10:0] s_sketch_high,a_sketch_high;
 reg [1:0] s_edge_width,a_edge_width;
 reg [1:0] s_sketch_width,a_sketch_width;
 reg pending,dirty;reg [15:0] shadow_id,active_id,commit_req;
 assign o_cfg_id=i_sof&&pending?shadow_id:active_id;
 assign o_mode=i_sof&&pending?s_mode:a_mode;
 assign o_ae_en=i_sof&&pending?s_ae_en:a_ae_en;
 assign o_wb_mode=i_sof&&pending?s_wb_mode:a_wb_mode;
 assign o_exposure=i_sof&&pending?s_exposure:a_exposure;
 assign o_gain=i_sof&&pending?s_gain:a_gain;
 assign o_kelvin=i_sof&&pending?s_kelvin:a_kelvin;
 assign o_gain_r=i_sof&&pending?s_gain_r:a_gain_r;
 assign o_gain_g=i_sof&&pending?s_gain_g:a_gain_g;
 assign o_gain_b=i_sof&&pending?s_gain_b:a_gain_b;
 assign o_swap=i_sof&&pending?s_swap:a_swap;
 assign o_tone=i_sof&&pending?s_tone:a_tone;
 assign o_osd=i_sof&&pending?s_osd:a_osd;
 assign o_binary=i_sof&&pending?s_binary:a_binary;
 assign o_edge_low=i_sof&&pending?s_edge_low:a_edge_low;
 assign o_edge_high=i_sof&&pending?s_edge_high:a_edge_high;
 assign o_sketch_low=i_sof&&pending?s_sketch_low:a_sketch_low;
 assign o_sketch_high=i_sof&&pending?s_sketch_high:a_sketch_high;
 assign o_edge_width=i_sof&&pending?s_edge_width:a_edge_width;
 assign o_sketch_width=i_sof&&pending?s_sketch_width:a_sketch_width;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   // Power-on defaults: automatic exposure and calibrated white balance.
   s_mode<=8'd0;a_mode<=8'd0;s_ae_en<=1'd1;a_ae_en<=1'd1;s_wb_mode<=2'd0;a_wb_mode<=2'd0;s_exposure<=16'd500;a_exposure<=16'd500;s_gain<=8'd108;a_gain<=8'd108;s_kelvin<=7'd65;a_kelvin<=7'd65;s_gain_r<=11'd344;a_gain_r<=11'd344;s_gain_g<=11'd256;a_gain_g<=11'd256;s_gain_b<=11'd451;a_gain_b<=11'd451;s_swap<=1'd0;a_swap<=1'd0;s_tone<=1'd0;a_tone<=1'd0;s_osd<=1'd1;a_osd<=1'd1;s_binary<=8'd130;a_binary<=8'd130;s_edge_low<=11'd45;a_edge_low<=11'd45;s_edge_high<=11'd90;a_edge_high<=11'd90;s_sketch_low<=11'd50;a_sketch_low<=11'd50;s_sketch_high<=11'd100;a_sketch_high<=11'd100;s_edge_width<=2'd1;a_edge_width<=2'd1;s_sketch_width<=2'd1;a_sketch_width<=2'd1;
   pending<=0;dirty<=0;shadow_id<=0;active_id<=0;commit_req<=0;
   o_reply_valid<=0;o_reply_req<=0;o_reply_cfg<=0;o_reply_status<=0;o_reply_value<=0;
   o_sensor_valid<=0;o_sensor_exp<=500;o_sensor_gain<=108;o_sync_rx_tick<=0;o_sync_id<=0;
  end else begin
   o_reply_valid<=0;o_sensor_valid<=0;
   if(i_sof&&pending)begin
    a_mode<=s_mode;a_ae_en<=s_ae_en;a_wb_mode<=s_wb_mode;a_exposure<=s_exposure;a_gain<=s_gain;a_kelvin<=s_kelvin;a_gain_r<=s_gain_r;a_gain_g<=s_gain_g;a_gain_b<=s_gain_b;a_swap<=s_swap;a_tone<=s_tone;a_osd<=s_osd;a_binary<=s_binary;a_edge_low<=s_edge_low;a_edge_high<=s_edge_high;a_sketch_low<=s_sketch_low;a_sketch_high<=s_sketch_high;a_edge_width<=s_edge_width;a_sketch_width<=s_sketch_width;
    active_id<=shadow_id;pending<=0;dirty<=0;
    o_reply_valid<=1;o_reply_cfg<=shadow_id;o_reply_req<=commit_req;o_reply_status<=2;
    if(s_exposure!=a_exposure||s_gain!=a_gain)begin o_sensor_valid<=1;o_sensor_exp<=s_exposure;o_sensor_gain<=s_gain;end
   end
   if(!pending && (i_next||i_prev))begin
    s_mode<=a_mode;s_ae_en<=a_ae_en;s_wb_mode<=a_wb_mode;s_exposure<=a_exposure;s_gain<=a_gain;s_kelvin<=a_kelvin;s_gain_r<=a_gain_r;s_gain_g<=a_gain_g;s_gain_b<=a_gain_b;s_swap<=a_swap;s_tone<=a_tone;s_osd<=a_osd;s_binary<=a_binary;s_edge_low<=a_edge_low;s_edge_high<=a_edge_high;s_sketch_low<=a_sketch_low;s_sketch_high<=a_sketch_high;s_edge_width<=a_edge_width;s_sketch_width<=a_sketch_width;
    s_mode<=i_next?(a_mode==MODE_COUNT-1?0:a_mode+1'b1):(a_mode==0?MODE_COUNT-1:a_mode-1'b1);
    shadow_id<=active_id+1'b1;pending<=1;dirty<=1;commit_req<=0;
   end
   if(i_legacy_valid)begin
    if(!pending)begin
    s_mode<=a_mode;s_ae_en<=a_ae_en;s_wb_mode<=a_wb_mode;s_exposure<=a_exposure;s_gain<=a_gain;s_kelvin<=a_kelvin;s_gain_r<=a_gain_r;s_gain_g<=a_gain_g;s_gain_b<=a_gain_b;s_swap<=a_swap;s_tone<=a_tone;s_osd<=a_osd;s_binary<=a_binary;s_edge_low<=a_edge_low;s_edge_high<=a_edge_high;s_sketch_low<=a_sketch_low;s_sketch_high<=a_sketch_high;s_edge_width<=a_edge_width;s_sketch_width<=a_sketch_width;end
    shadow_id<=active_id+1'b1;pending<=1;dirty<=1;commit_req<=0;
    case(i_legacy_cmd)
     1:begin s_exposure<=i_legacy_value<62?62:i_legacy_value>1800?1800:i_legacy_value[15:0];s_ae_en<=0;end
     2:s_gain_r<=i_legacy_value<64?64:i_legacy_value>1024?1024:i_legacy_value[10:0];
     3:s_gain_g<=i_legacy_value<64?64:i_legacy_value>1024?1024:i_legacy_value[10:0];
     4:s_gain_b<=i_legacy_value<64?64:i_legacy_value>1024?1024:i_legacy_value[10:0];
     5:s_swap<=i_legacy_value[0];
     6:s_wb_mode<=i_legacy_value[0]?0:(a_kelvin==0?2:1);
     7:begin s_kelvin<=i_legacy_value[6:0];s_wb_mode<=i_legacy_value==0?2:1;end
     default:begin pending<=0;dirty<=0;end
    endcase
   end
   if(i_valid)begin
    o_reply_valid<=1;o_reply_req<=i_req_id;o_reply_cfg<=active_id;o_reply_value<=0;o_reply_status<=0;
    if(i_op==4)begin o_sync_id<=i_req_id;o_sync_rx_tick<=i_ticks;o_reply_status<=6;end
    else if(i_op==3)begin case(i_addr)
0:o_reply_value<=a_mode;
1:o_reply_value<=a_ae_en;
2:o_reply_value<=a_wb_mode;
3:o_reply_value<=a_exposure;
4:o_reply_value<=a_gain;
5:o_reply_value<=a_kelvin;
6:o_reply_value<=a_gain_r;
7:o_reply_value<=a_gain_g;
8:o_reply_value<=a_gain_b;
9:o_reply_value<=a_swap;
10:o_reply_value<=a_tone;
11:o_reply_value<=a_osd;
12:o_reply_value<=a_binary;
13:o_reply_value<=a_edge_low;
14:o_reply_value<=a_edge_high;
15:o_reply_value<=a_sketch_low;
16:o_reply_value<=a_sketch_high;
17:o_reply_value<=a_edge_width;
18:o_reply_value<=a_sketch_width;
     default:o_reply_status<=4;
    endcase end
    else if(i_op==2 && i_cfg_id==active_id)begin o_reply_status<=2;end
    else if(pending || i_next || i_prev || i_legacy_valid)begin o_reply_status<=3;end
    else if(i_op==1)begin
     if(i_cfg_id!=shadow_id)begin s_mode<=a_mode;s_ae_en<=a_ae_en;s_wb_mode<=a_wb_mode;s_exposure<=a_exposure;s_gain<=a_gain;s_kelvin<=a_kelvin;s_gain_r<=a_gain_r;s_gain_g<=a_gain_g;s_gain_b<=a_gain_b;s_swap<=a_swap;s_tone<=a_tone;s_osd<=a_osd;s_binary<=a_binary;s_edge_low<=a_edge_low;s_edge_high<=a_edge_high;s_sketch_low<=a_sketch_low;s_sketch_high<=a_sketch_high;s_edge_width<=a_edge_width;s_sketch_width<=a_sketch_width; shadow_id<=i_cfg_id;end
     dirty<=1;
     case(i_addr)
0:if(i_value<MODE_COUNT)s_mode<=i_value[7:0];else begin o_reply_status<=4;dirty<=0;end
1:if(i_value>=0 && i_value<=1)s_ae_en<=i_value[0:0];else begin o_reply_status<=4;dirty<=0;end
2:if(i_value>=0 && i_value<=3)s_wb_mode<=i_value[1:0];else begin o_reply_status<=4;dirty<=0;end
3:if(i_value>=62 && i_value<=1800)s_exposure<=i_value[15:0];else begin o_reply_status<=4;dirty<=0;end
4:if(i_value>=16 && i_value<=143)s_gain<=i_value[7:0];else begin o_reply_status<=4;dirty<=0;end
5:if(i_value>=25 && i_value<=100)s_kelvin<=i_value[6:0];else begin o_reply_status<=4;dirty<=0;end
6:if(i_value>=64 && i_value<=1024)s_gain_r<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
7:if(i_value>=64 && i_value<=1024)s_gain_g<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
8:if(i_value>=64 && i_value<=1024)s_gain_b<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
9:if(i_value>=0 && i_value<=1)s_swap<=i_value[0:0];else begin o_reply_status<=4;dirty<=0;end
10:if(i_value>=0 && i_value<=1)s_tone<=i_value[0:0];else begin o_reply_status<=4;dirty<=0;end
11:if(i_value>=0 && i_value<=1)s_osd<=i_value[0:0];else begin o_reply_status<=4;dirty<=0;end
12:if(i_value>=0 && i_value<=255)s_binary<=i_value[7:0];else begin o_reply_status<=4;dirty<=0;end
13:if(i_value>=0 && i_value<=2040)s_edge_low<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
14:if(i_value>=0 && i_value<=2040)s_edge_high<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
15:if(i_value>=0 && i_value<=2040)s_sketch_low<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
16:if(i_value>=0 && i_value<=2040)s_sketch_high<=i_value[10:0];else begin o_reply_status<=4;dirty<=0;end
17:if(i_value>=1 && i_value<=2)s_edge_width<=i_value[1:0];else begin o_reply_status<=4;dirty<=0;end
18:if(i_value>=1 && i_value<=2)s_sketch_width<=i_value[1:0];else begin o_reply_status<=4;dirty<=0;end
      default:begin o_reply_status<=4;dirty<=0;end
     endcase
    end else if(i_op==2 && dirty && i_cfg_id==shadow_id)begin
     if(s_edge_low>s_edge_high||s_sketch_low>s_sketch_high)begin o_reply_status<=4;dirty<=0;end
     else begin pending<=1;commit_req<=i_req_id;o_reply_status<=1;o_reply_cfg<=shadow_id; end
    end else o_reply_status<=4;
   end
  end
 end
endmodule
