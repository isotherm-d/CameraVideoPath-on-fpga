// Public CVP_PIXEL_V1 algorithm wrapper. Reserved bits and metadata stay typed.
module cvp_style_stream #(parameter W=1280,H=720,USE_CONTOUR=0)(
 input clk,rst_n,i_valid,input [127:0] i_pixel,
 input [7:0] i_binary_th,input [10:0] i_edge_low,i_edge_high,
 input [1:0] i_edge_width,
 output o_valid,output [127:0] o_pixel,output o_overflow
);
 wire [23:0] rgb;wire sof,eol,eof,osd,ae;wire [1:0] wb;
 wire [11:0] x,y;wire [31:0] fid;wire [15:0] cfg;wire [7:0] mode;
 wire base_valid,base_overflow;wire [127:0] base_pixel;
 cvp_style #(.W(W),.H(H)) core(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_rgb(i_pixel[23:0]),
 .i_sof(i_pixel[104]),.i_frame_id(i_pixel[79:48]),.i_cfg_id(i_pixel[95:80]),.i_mode(i_pixel[103:96]),
 .i_osd_en(i_pixel[108]),.i_ae_en(i_pixel[109]),.i_wb_mode(i_pixel[111:110]),
 .i_binary_th(i_binary_th),.i_edge_low(USE_CONTOUR?11'd130:i_edge_low),.i_edge_high(USE_CONTOUR?11'd190:i_edge_high),
 .o_valid(base_valid),.o_rgb(rgb),.o_sof(sof),.o_eol(eol),.o_eof(eof),.o_x(x),.o_y(y),
 .o_frame_id(fid),.o_cfg_id(cfg),.o_mode(mode),.o_osd_en(osd),.o_ae_en(ae),.o_wb_mode(wb),.o_overflow(base_overflow));
 assign base_pixel={16'd0,wb,ae,osd,i_pixel[107],eof,eol,sof,mode,cfg,fid,y,x,rgb};
 generate if(USE_CONTOUR)begin:enhanced
  wire cv,cf;wire [127:0] contour_pixel;
  cvp_contour #(.W(W),.H(H)) contour(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_pixel(i_pixel),
   .i_low(i_edge_low),.i_high(i_edge_high),.i_width(i_edge_width),.o_valid(cv),.o_pixel(contour_pixel),.o_overflow(cf));
  wire use_base=base_valid&&mode!=3&&mode!=5;
  wire use_contour=cv&&(contour_pixel[103:96]==3||contour_pixel[103:96]==5);
  assign o_valid=use_base||use_contour;
  assign o_pixel=use_contour?contour_pixel:base_pixel;
  assign o_overflow=base_overflow||cf||(use_base&&use_contour);
 end else begin:legacy
  assign o_valid=base_valid;assign o_pixel=base_pixel;assign o_overflow=base_overflow;
 end endgenerate
endmodule
