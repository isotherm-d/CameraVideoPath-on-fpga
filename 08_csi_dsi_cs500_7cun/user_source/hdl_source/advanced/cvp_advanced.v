module cvp_advanced #(parameter W=1280,H=720)(
 input clk,rst_n,input i_capture_valid,input i_capture_event,input [1:0] keys_n,
 input i_valid,i_sof,input [23:0] i_rgb,
 input cmd_valid,input [15:0] cmd_req,cmd_cfg,input [7:0] cmd_op,cmd_addr,input [31:0] cmd_value,
 input legacy_valid,input [7:0] legacy_cmd,input [23:0] legacy_value,
 input cfg_clk,i_cam_done,i_ae_done,i_iic_error,i_cfg_error,
 output sensor_req,output [15:0] sensor_exp_cfg,sensor_gain_cfg,
 output o_valid,o_sof,o_eof,output [23:0] o_rgb,output [31:0] o_frame_id,
 output [1023:0] status_data,output status_valid,input status_ready,
 input i_net_overflow,input i_net_tx_done,input [31:0] i_net_tx_fid,input net_clk,net_rst_n,
 // Canonical, unstylized image connection for a teammate ROI producer.
 output clean_valid,clean_sof,clean_eol,clean_eof,output [23:0] clean_rgb,
 output [11:0] clean_x,clean_y,output [31:0] clean_frame_id,output [15:0] clean_cfg_id,output [127:0] clean_pixel,
 output [63:0] time_ticks,
 input [63:0] result_done_tick,input result_valid,output result_ready,input [31:0] result_frame,input [15:0] result_roi,
 input [7:0] result_class,input [63:0] result_bbox,input [31:0] result_score,input [6:0] result_format
);
 wire [7:0] cfg_mode;
 wire [0:0] cfg_ae_en;
 wire [1:0] cfg_wb_mode;
 wire [15:0] cfg_exposure;
 wire [7:0] cfg_gain;
 wire [6:0] cfg_kelvin;
 wire [10:0] cfg_gain_r;
 wire [10:0] cfg_gain_g;
 wire [10:0] cfg_gain_b;
 wire [0:0] cfg_swap;
 wire [0:0] cfg_tone;
 wire [0:0] cfg_osd;
 wire [7:0] cfg_binary;
 wire [10:0] cfg_edge_low;
 wire [10:0] cfg_edge_high;
 wire [15:0] cfg_id;
 reg [63:0] ticks,capture_mem[0:3];reg [31:0] capture_id;
 assign time_ticks=ticks;
 reg [31:0] source_groups;reg source_started,source_error;
 integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin ticks<=0;capture_id<=0;source_groups<=0;source_started<=0;source_error<=0;for(k=0;k<4;k=k+1)capture_mem[k]<=0;end
  else begin
   ticks<=ticks+1'b1;source_error<=0;
   if(i_capture_valid)begin
    if(i_capture_event)begin
     if(source_started&&source_groups!=W*H/4)source_error<=1;
     source_groups<=1;source_started<=1;
    end else if(source_started)source_groups<=source_groups+1'b1;
   end
   if(i_capture_event)begin capture_mem[capture_id[1:0]]<=ticks;capture_id<=capture_id+1'b1;end end
 end
 wire next,prev;
 cvp_keys keys(.clk(clk),.rst_n(rst_n),.keys_n(keys_n),.next(next),.prev(prev));
 wire manual_valid;wire [15:0] manual_exp;wire [7:0] manual_gain;
 wire reply_valid;wire [15:0] reply_req,reply_cfg;wire [7:0] reply_status;wire [31:0] reply_value;
 wire [63:0] sync_rx;wire [15:0] sync_id;
 cvp_cfg_ctrl control(.clk(clk),.rst_n(rst_n),.i_sof(i_valid&&i_sof),.i_next(next),.i_prev(prev),
 .i_valid(cmd_valid),.i_req_id(cmd_req),.i_cfg_id(cmd_cfg),.i_op(cmd_op),.i_addr(cmd_addr),.i_value(cmd_value),
 .i_legacy_valid(legacy_valid),.i_legacy_cmd(legacy_cmd),.i_legacy_value(legacy_value),.i_ticks(ticks),
 .o_mode(cfg_mode),.o_ae_en(cfg_ae_en),.o_wb_mode(cfg_wb_mode),.o_exposure(cfg_exposure),.o_gain(cfg_gain),.o_kelvin(cfg_kelvin),.o_gain_r(cfg_gain_r),.o_gain_g(cfg_gain_g),.o_gain_b(cfg_gain_b),.o_swap(cfg_swap),.o_tone(cfg_tone),.o_osd(cfg_osd),.o_binary(cfg_binary),.o_edge_low(cfg_edge_low),.o_edge_high(cfg_edge_high),.o_cfg_id(cfg_id),.o_sensor_valid(manual_valid),.o_sensor_exp(manual_exp),.o_sensor_gain(manual_gain),
 .o_reply_valid(reply_valid),.o_reply_req(reply_req),.o_reply_cfg(reply_cfg),.o_reply_status(reply_status),
 .o_reply_value(reply_value),.o_sync_rx_tick(sync_rx),.o_sync_id(sync_id));
 wire rv,rs,rl,re,frame_error;wire [23:0] raw_rgb;wire [11:0] rx,ry;wire [31:0] rf;
 wire [15:0] rc;wire [7:0] rm;
 cvp_stream_tag #(.W(W),.H(H)) tag(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_rgb(i_rgb),.i_sof(i_sof),
 .i_cfg_id(cfg_id),.i_mode(cfg_mode),.o_valid(rv),.o_rgb(raw_rgb),.o_sof(rs),.o_eol(rl),.o_eof(re),
 .o_x(rx),.o_y(ry),.o_frame_id(rf),.o_cfg_id(rc),.o_mode(rm),.o_ticks(),.o_capture_tick(),.o_frame_error(frame_error));
 reg fault;
 wire stats_done,stats_overrun;wire [7:0] mean,black,white;wire [10:0] awb_r,awb_g,awb_b;
 wire [1:0] awb_state;wire [31:0] samples,neutrals,clipped;
 wire [10:0] temp_r,temp_b;
 cvp_temperature temperature(.i_kelvin(cfg_kelvin),.o_r(temp_r),.o_b(temp_b));
 reg [10:0] gr_tag,gg_tag,gb_tag;reg swap_tag;reg [3:0] flags_tag;
 reg [7:0] binary_tag;reg [21:0] edge_tag;
 wire [10:0] selected_r=cfg_wb_mode==3?awb_r:cfg_wb_mode==2?cfg_gain_r:cfg_wb_mode==1?temp_r:11'd344;
 wire [10:0] selected_g=cfg_wb_mode==3?awb_g:cfg_wb_mode==2?cfg_gain_g:11'd256;
 wire [10:0] selected_b=cfg_wb_mode==3?awb_b:cfg_wb_mode==2?cfg_gain_b:cfg_wb_mode==1?temp_b:11'd451;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin gr_tag<=344;gg_tag<=256;gb_tag<=451;swap_tag<=0;flags_tag<=4'b1000;binary_tag<=130;edge_tag<={11'd130,11'd190};end
  else if(i_valid&&i_sof)begin
   gr_tag<=selected_r;gg_tag<=selected_g;gb_tag<=selected_b;swap_tag<=cfg_swap;
   flags_tag<={cfg_osd,cfg_ae_en,cfg_wb_mode};binary_tag<=cfg_binary;edge_tag<={cfg_edge_low,cfg_edge_high};
  end
 end
 cvp_gain11 gain(.clk(clk),.rst_n(rst_n),.i_valid(rv),.i_sof(rs),.i_rgb(raw_rgb),
 .i_r(gr_tag),.i_g(gg_tag),.i_b(gb_tag),.i_swap(swap_tag),.o_valid(clean_valid),.o_sof(clean_sof),.o_rgb(clean_rgb));
 reg [79:0] cc_meta;reg [23:0] cc_raw;reg [3:0] cc_flags;reg [7:0] cc_binary;reg [21:0] cc_edges;
 always @(posedge clk)begin cc_meta<={rx,ry,rf,rc,rm};cc_raw<=raw_rgb;cc_flags<=flags_tag;cc_binary<=binary_tag;cc_edges<=edge_tag;end
 assign clean_x=cc_meta[79:68];assign clean_y=cc_meta[67:56];assign clean_frame_id=cc_meta[55:24];
 assign clean_pixel={16'd0,cc_flags[1:0],cc_flags[2],cc_flags[3],fault,clean_eof,clean_eol,clean_sof,8'd0,clean_cfg_id,clean_frame_id,clean_y,clean_x,clean_rgb};
 assign clean_cfg_id=cc_meta[23:8];assign clean_eol=clean_valid&&clean_x==W-1;
 assign clean_eof=clean_eol&&clean_y==H-1;
 cvp_frame_stats #(.W(W),.H(H)) stats(.clk(clk),.rst_n(rst_n),
 .i_valid(clean_valid),.i_sof(clean_sof),.i_eof(clean_eof),.i_rgb(clean_rgb),.i_raw_rgb(cc_raw),.i_awb_en(cfg_wb_mode==3&&!fault),
 .o_done(stats_done),.o_mean(mean),.o_black(black),.o_white(white),.o_awb_r(awb_r),.o_awb_g(awb_g),.o_awb_b(awb_b),
 .o_awb_state(awb_state),.o_samples(samples),.o_neutral(neutrals),.o_clipped(clipped),.o_stat_overrun(stats_overrun));
 reg cam1,cam2,err1,err2;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin cam1<=0;cam2<=0;err1<=0;err2<=0;end
  else begin cam1<=i_cam_done;cam2<=cam1;err1<=i_cfg_error;err2<=err1;end
 end
 wire ae_valid,sensor_busy,sensor_done,sensor_error;wire [15:0] ae_exp,sensor_exp;wire [7:0] ae_gain,sensor_gain;
 cvp_ae_control ae(.clk(clk),.rst_n(rst_n),.i_frame_done(stats_done),.i_en(cfg_ae_en&&!fault),
 .i_ready(cam2),.i_busy(sensor_busy),.i_mean(mean),.i_clipped(clipped),.i_samples(samples),
 .i_exp(sensor_exp),.i_gain(sensor_gain),.o_valid(ae_valid),.o_exp(ae_exp),.o_gain(ae_gain));
 cvp_sensor_bridge sensor(.clk(clk),.rst_n(rst_n),.i_valid(manual_valid||ae_valid),
 .i_exp(manual_valid?manual_exp:ae_exp),.i_gain(manual_valid?manual_gain:ae_gain),.o_busy(sensor_busy),
 .o_exp(sensor_exp),.o_gain(sensor_gain),.o_done(sensor_done),.o_error(sensor_error),
 .cfg_clk(cfg_clk),.cfg_rst_n(rst_n),.i_cfg_done(i_cam_done),.i_ae_done(i_ae_done),.i_iic_error(i_iic_error),
 .o_req(sensor_req),.o_cfg_exp(sensor_exp_cfg),.o_cfg_gain(sensor_gain_cfg));
 wire tv,ts;wire [23:0] trgb;
 cvp_tone tone(.clk(clk),.rst_n(rst_n),.i_valid(clean_valid),.i_sof(clean_sof),.i_rgb(clean_rgb),.i_en(cfg_tone),
 .i_stats_done(stats_done),.i_black(black),.i_white(white),.o_valid(tv),.o_sof(ts),.o_rgb(trgb));
 reg [79:0] tone_meta;reg [3:0] tone_flags;reg [7:0] tone_binary;reg [21:0] tone_edges;
 always @(posedge clk)begin tone_meta<=cc_meta;tone_flags<=cc_flags;tone_binary<=cc_binary;tone_edges<=cc_edges;end
 wire fv,fs,fl,fe,style_overflow;wire [23:0] frgb;wire [11:0] fx,fy;wire [31:0] ff;wire [15:0] fc;
 wire [7:0] fm;wire fosd,fae;wire [1:0] fwb;
 wire [127:0] display_input,display_pixel;
 assign display_input={16'd0,tone_flags[1:0],tone_flags[2],tone_flags[3],fault,
  (tv&&tone_meta[79:68]==W-1&&tone_meta[67:56]==H-1),
  (tv&&tone_meta[79:68]==W-1),ts,tone_meta[7:0],tone_meta[23:8],tone_meta[55:24],tone_meta[67:56],tone_meta[79:68],trgb};
 cvp_style_stream #(.W(W),.H(H)) style(.clk(clk),.rst_n(rst_n),.i_valid(tv),.i_pixel(display_input),
 .i_binary_th(tone_binary),.i_edge_low(tone_edges[21:11]),.i_edge_high(tone_edges[10:0]),
 .o_valid(fv),.o_pixel(display_pixel),.o_overflow(style_overflow));
 assign frgb=display_pixel[23:0];assign fx=display_pixel[35:24];assign fy=display_pixel[47:36];
 assign ff=display_pixel[79:48];assign fc=display_pixel[95:80];assign fm=display_pixel[103:96];
 assign fs=display_pixel[104];assign fl=display_pixel[105];assign fe=display_pixel[106];
 assign fosd=display_pixel[108];assign fae=display_pixel[109];assign fwb=display_pixel[111:110];
 cvp_osd_stream osd(.clk(clk),.rst_n(rst_n),.i_valid(fv),.i_sof(fs),.i_eol(fl),.i_eof(fe),.i_rgb(frgb),
 .i_x(fx),.i_y(fy),.i_frame_id(ff),.i_cfg_id(fc),.i_mode(fm),.i_en(fosd),.i_ae(fae),.i_wb(fwb),
 .o_valid(o_valid),.o_sof(o_sof),.o_eol(),.o_eof(o_eof),.o_rgb(o_rgb),.o_frame_id(o_frame_id));
 reg [63:0] process_tick,last_capture,last_process,last_eof,last_tx_tick;
 reg [31:0] last_fid,stream_errors,sensor_errors,last_tx_fid;reg [15:0] last_cfg;reg [7:0] last_mode;
 reg fe_delayed,tx_delayed;reg [23:0] heartbeat;
 wire tx_valid;wire [31:0] tx_fid;
 cvp_mailbox #(.DW(32)) tx_event(.s_clk(net_clk),.s_rst_n(net_rst_n),.s_valid(i_net_tx_done),.s_data(i_net_tx_fid),.s_ready(),
 .m_clk(clk),.m_rst_n(rst_n),.m_valid(tx_valid),.m_data(tx_fid),.m_ready(1'b1));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin process_tick<=0;last_capture<=0;last_process<=0;last_eof<=0;last_tx_tick<=0;
   last_fid<=32'hffffffff;last_cfg<=0;last_mode<=0;last_tx_fid<=32'hffffffff;
   stream_errors<=0;sensor_errors<=0;fault<=0;fe_delayed<=0;tx_delayed<=0;heartbeat<=0;end
  else begin
   heartbeat<=heartbeat==10000000?0:heartbeat+1'b1;fe_delayed<=fv&&fe;tx_delayed<=tx_valid;
   if(fv&&fs)process_tick<=ticks;
   if(fv&&fe)begin last_fid<=ff;last_cfg<=fc;last_mode<=fm;
    last_capture<=capture_mem[ff[1:0]];last_process<=process_tick;last_eof<=ticks;end
   if(tx_valid)begin last_tx_fid<=tx_fid;last_tx_tick<=ticks;end
   if(frame_error||style_overflow||stats_overrun||i_net_overflow||source_error)begin stream_errors<=stream_errors+1'b1;fault<=1;end
   if(sensor_done&&sensor_error)sensor_errors<=sensor_errors+1'b1;
  end
 end
 reg result_pending;reg [31:0] res_frame,res_score;reg [15:0] res_roi;reg [7:0] res_class,res_flags;reg [63:0] res_bbox,res_tick;
 assign result_ready=!result_pending;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin result_pending<=0;res_frame<=0;res_score<=0;res_roi<=0;res_class<=0;res_flags<=0;res_bbox<=0;res_tick<=0;end
  else begin
   if(status_valid&&status_ready)result_pending<=0;
   if(result_valid&&result_ready)begin
    result_pending<=1;res_frame<=result_frame;res_score<=result_score;res_roi<=result_roi;
    res_class<=result_class;res_bbox<=result_bbox;res_flags<={result_format,1'b1};res_tick<=result_done_tick==0?ticks:result_done_tick;
   end
  end
 end
 wire [31:0] process_delta=last_process-last_capture,eof_delta=last_eof-last_capture;
 wire [7:0] flags={cfg_wb_mode==3,cam2,fault,(sensor_error||err2),sensor_busy,cfg_osd,cfg_tone,cfg_ae_en};
 assign status_data={32'h43563236,8'd1,last_mode,{6'd0,cfg_wb_mode},flags,last_fid,cfg_id,reply_req,reply_status,sensor_gain,sensor_exp,{5'd0,gr_tag},{5'd0,gg_tag},{5'd0,gb_tag},16'd1280,16'd720,16'd30,mean,black,white,{6'd0,awb_state},last_capture,process_delta,eof_delta,ticks,sync_rx,sync_id,16'd0,stream_errors,sensor_errors,last_tx_fid,last_tx_tick,res_flags,res_class,res_roi,res_frame,res_bbox,res_score,res_tick,last_cfg,reply_value,16'd0};
 assign status_valid=(reply_valid||fe_delayed||tx_delayed||result_pending||heartbeat==10000000)&&status_ready;
endmodule
