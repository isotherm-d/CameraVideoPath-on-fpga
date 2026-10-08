// Public CVP_PIXEL_V1 algorithm wrapper. Reserved bits and metadata stay typed.
module cvp_style_stream #(parameter W=1280,H=720)(
 input clk,rst_n,i_valid,input [127:0] i_pixel,
 input [7:0] i_binary_th,input [10:0] i_edge_low,i_edge_high,
 output o_valid,output [127:0] o_pixel,output o_overflow
);
 wire [23:0] rgb;wire sof,eol,eof,osd,ae;wire [1:0] wb;
 wire [11:0] x,y;wire [31:0] fid;wire [15:0] cfg;wire [7:0] mode;
 cvp_style #(.W(W),.H(H)) core(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_rgb(i_pixel[23:0]),
 .i_sof(i_pixel[104]),.i_frame_id(i_pixel[79:48]),.i_cfg_id(i_pixel[95:80]),.i_mode(i_pixel[103:96]),
 .i_osd_en(i_pixel[108]),.i_ae_en(i_pixel[109]),.i_wb_mode(i_pixel[111:110]),
 .i_binary_th(i_binary_th),.i_edge_low(i_edge_low),.i_edge_high(i_edge_high),
 .o_valid(o_valid),.o_rgb(rgb),.o_sof(sof),.o_eol(eol),.o_eof(eof),.o_x(x),.o_y(y),
 .o_frame_id(fid),.o_cfg_id(cfg),.o_mode(mode),.o_osd_en(osd),.o_ae_en(ae),.o_wb_mode(wb),.o_overflow(o_overflow));
 assign o_pixel={16'd0,wb,ae,osd,i_pixel[107],eof,eol,sof,mode,cfg,fid,y,x,rgb};
endmodule
