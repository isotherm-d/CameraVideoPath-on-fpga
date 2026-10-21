// A3 差分验证: cvp_style / cvp_contour 新(pend 寄存器)旧(元数据 FIFO)对照。
// 同一 128bit token 流驱动两套 DUT, 逐拍比对全部输出与 o_valid 对齐。
// 模式 0..6 全覆盖, 随机阈值/坐标/帧号, valid 中断流。
`timescale 1ns/1ps
module tb_opt_style;
 localparam W=128,H=72;
 reg clk=0,rst=0;
 always #5 clk=~clk;

 // ---- 共用 token 流发生 ----
 reg v=0;reg [127:0] tok=0;
 reg [31:0] lfsr=32'hBEEF_CAFE;
 function [31:0] prng;input [31:0] s;begin prng={s[6:0],s[15:0],s[22:16]}^({s[6:0],s[15:0],s[22:16]}<<9)^(s[31:23]);end endfunction
 reg [11:0] x,y;reg [31:0] fid=0;reg [15:0] cfg=0;reg [7:0] mode=0;
 reg [7:0] bth;reg [10:0] elow,ehigh;reg [1:0] ewid;
 integer gap;
 reg [127:0] tok_g,tok_c;   // 金/新各一份(同值)

 // ---- style 金/新 ----
 wire s_v,s_gv;wire [23:0] s_rgb,s_grgb;wire s_sof,s_gsof,s_eol,s_geol,s_eof,s_geof,s_ovf,s_govf;
 wire [11:0] s_x,s_gx,s_y,s_gy;wire [31:0] s_fid,s_gfid;wire [15:0] s_cfg,s_gcfg;
 wire [7:0] s_mode,s_gmode;wire s_osd,s_gosd,s_ae,s_gae;wire [1:0] s_wb,s_gwb;
 cvp_style      #(.W(W),.H(H)) sd (.clk(clk),.rst_n(rst),.i_valid(v),.i_rgb(tok[23:0]),.i_sof(tok[104]),
  .i_frame_id(tok[79:48]),.i_cfg_id(tok[95:80]),.i_mode(tok[103:96]),.i_osd_en(tok[108]),.i_ae_en(tok[109]),.i_wb_mode(tok[111:110]),
  .i_binary_th(bth),.i_edge_low(elow),.i_edge_high(ehigh),
  .o_osd_en(s_osd),.o_ae_en(s_ae),.o_wb_mode(s_wb),.o_valid(s_v),.o_rgb(s_rgb),.o_sof(s_sof),.o_eol(s_eol),.o_eof(s_eof),
  .o_x(s_x),.o_y(s_y),.o_frame_id(s_fid),.o_cfg_id(s_cfg),.o_mode(s_mode),.o_overflow(s_ovf));
 cvp_style_v30_gold #(.W(W),.H(H)) sg (.clk(clk),.rst_n(rst),.i_valid(v),.i_rgb(tok_g[23:0]),.i_sof(tok_g[104]),
  .i_frame_id(tok_g[79:48]),.i_cfg_id(tok_g[95:80]),.i_mode(tok_g[103:96]),.i_osd_en(tok_g[108]),.i_ae_en(tok_g[109]),.i_wb_mode(tok_g[111:110]),
  .i_binary_th(bth),.i_edge_low(elow),.i_edge_high(ehigh),
  .o_osd_en(s_gosd),.o_ae_en(s_gae),.o_wb_mode(s_gwb),.o_valid(s_gv),.o_rgb(s_grgb),.o_sof(s_gsof),.o_eol(s_geol),.o_eof(s_geof),
  .o_x(s_gx),.o_y(s_gy),.o_frame_id(s_gfid),.o_cfg_id(s_gcfg),.o_mode(s_gmode),.o_overflow(s_govf));

 // ---- contour 金/新 ----
 wire c_v,c_gv;wire [127:0] c_pix,c_gpix;wire c_ovf,c_govf;
 cvp_contour      #(.W(W),.H(H)) cd (.clk(clk),.rst_n(rst),.i_valid(v),.i_pixel(tok),
  .i_low(elow),.i_high(ehigh),.i_width(ewid),.o_valid(c_v),.o_pixel(c_pix),.o_overflow(c_ovf));
 cvp_contour_gold #(.W(W),.H(H)) cg (.clk(clk),.rst_n(rst),.i_valid(v),.i_pixel(tok_g),
  .i_low(elow),.i_high(ehigh),.i_width(ewid),.o_valid(c_gv),.o_pixel(c_gpix),.o_overflow(c_govf));

 integer errors=0,frames=0,checked=0;reg warm=1;
 integer f,p,i;
 reg [23:0] px;
 task check_all;begin
  if(s_v!==s_gv||c_v!==c_gv||s_ovf!==s_govf||c_ovf!==c_govf)begin errors=errors+1;$display("F%0d valid misalign s%d/%d c%d/%d @%0t",frames,s_v,s_gv,c_v,c_gv,$time);end
  if(s_v)begin
   checked=checked+1;
   if(s_rgb!==s_grgb||s_sof!==s_gsof||s_eol!==s_geol||s_eof!==s_geof||s_x!==s_gx||s_y!==s_gy||
      s_fid!==s_gfid||s_cfg!==s_gcfg||s_mode!==s_gmode||s_osd!==s_gosd||s_ae!==s_gae||s_wb!==s_gwb)begin
    errors=errors+1;$display("F%0d style mismatch @%0t",frames,$time);end
  end
  if(c_v)begin
   if(c_pix!==c_gpix)begin errors=errors+1;$display("F%0d contour mismatch @%0t",frames,$time);end
  end
  if((^s_rgb)===1'bx)begin errors=errors+1;$display("F%0d style X @%0t",frames,$time);end
  if((^c_pix)===1'bx)begin
   errors=errors+1;
   if(errors<4)$display("F%0d contour X @%0t mode=%0d x=%0d y=%0d tok=%h pix=%h",frames,$time,tok[103:96],tok[35:24],tok[47:36],tok,c_pix);
  end
 end endtask

 always @(posedge clk)begin
  if(rst===1'b1&&!warm)begin
   check_all();
  end
 end

 initial begin
  #31;rst=1;#400; // 稳定期(直方图清扫对 style 无关, 保持一致习惯)
  // 预热 2 帧: 行缓存/窗口 RAM 未初始化的 X 只出现在上电首帧(两 DUT 相同),
  // 差分从第 3 帧开始计错
  for(f=0;f<3;f=f+1)begin frames=99;mode=0;bth=130;elow=130;ehigh=190;ewid=1;warm=1;fid=f;cfg=f+1;
   x=0;y=0;
   for(p=0;p<W*H;p=p+1)begin
    @(negedge clk);lfsr=prng(lfsr);px={lfsr[7:0],lfsr[15:8],lfsr[23:16]};
    v=1;x=p%W;y=p/W;
    tok={16'd0,2'd3,lfsr[31:30],1'b0,(p==W*H-1),(p%W==W-1),(p==0),mode,cfg,fid,y,x,px};
    tok_g=tok;
   end
   @(negedge clk);v=0;repeat(50)@(negedge clk);
  end
  for(f=0;f<14;f=f+1)begin
   frames=f;warm=0;
   lfsr=prng(lfsr);mode=f%7;fid=lfsr[27:0];cfg=lfsr[21:6];
   lfsr=prng(lfsr);bth=lfsr[7:0];elow=lfsr[26:16];ehigh=elow+lfsr[31:28]*8+11;
   ewid=(f%3)==0?2'd2:2'd1;
   x=0;y=0;
   for(p=0;p<W*H;p=p+1)begin
    @(negedge clk);
    lfsr=prng(lfsr);px={lfsr[7:0],lfsr[15:8],lfsr[23:16]};
    v=1;x=p%W;y=p/W;
    tok={16'd0,2'd3,lfsr[31:30],1'b0,(p==W*H-1),(p%W==W-1),(p==0),mode,cfg,fid,y,x,px};
    tok_g=tok;tok_c=tok;
    if(lfsr[3:0]<4)begin @(negedge clk);v=0;end
   end
   @(negedge clk);v=0;
   repeat(50)@(negedge clk); // 排空
  end
  if(errors==0)$display("TEST_RESULT PASS style_v30_equivalence %0d frames %0d samples",frames+1,checked);
  else $display("TEST_RESULT FAIL style_v30_equivalence %0d errors",errors);
  $finish;
 end
 initial begin #20000000;$display("TEST_RESULT FAIL style timeout f%0d",frames);$finish;end
endmodule
