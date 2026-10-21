`timescale 1ns/1ps
// Compare the local RAW delay against the board-passed cvp_proc + cvp_dpc.
module tb_opt_proc;
localparam W=32, H=16;
reg clk=0, rst=0;
always #5 clk=~clk;
reg [2:0] mode=0;
reg cfg=0, cmd_wr=0, gv=0, gfs=0, glast=0;
reg [15:0] cmd=0;
reg [39:0] gd=0;
wire nv,nfs,nlast,nreq,ov,ofs,olast,oreq;
wire [23:0] nrgb,orgb;
wire [15:0] nae,nag,oae,oag;
cvp_proc #(.IMG_W(W),.IMG_H(H)) dut (
 .i_clk(clk),.i_rst_n(rst),.i_mode(mode),.i_cam_cfg_done(cfg),
 .i_cmd_ae(cmd),.i_cmd_ae_wr(cmd_wr),.i_grp_valid(gv),.i_grp_data(gd),
 .i_grp_frame_start(gfs),.i_grp_line_last(glast),
 .o_pix_valid(nv),.o_pix_rgb(nrgb),.o_pix_frame_start(nfs),
 .o_pix_line_last(nlast),.o_ae_req(nreq),.o_ae(nae),.o_ag(nag));
cvp_proc_v30_gold #(.IMG_W(W),.IMG_H(H)) ref_dut (
 .i_clk(clk),.i_rst_n(rst),.i_mode(mode),.i_cam_cfg_done(cfg),
 .i_cmd_ae(cmd),.i_cmd_ae_wr(cmd_wr),.i_grp_valid(gv),.i_grp_data(gd),
 .i_grp_frame_start(gfs),.i_grp_line_last(glast),
 .o_pix_valid(ov),.o_pix_rgb(orgb),.o_pix_frame_start(ofs),
 .o_pix_line_last(olast),.o_ae_req(oreq),.o_ae(oae),.o_ag(oag));
integer cycles=0,valid_pixels=0,errors=0;
always @(posedge clk) begin
 #1;
 cycles=cycles+1;
 if(nv) valid_pixels=valid_pixels+1;
 if ({nv,nrgb,nfs,nlast,nreq,nae,nag} !==
     {ov,orgb,ofs,olast,oreq,oae,oag} ||
     {dut.w_dpc_valid,dut.w_dpc_fs,dut.w_dpc_raw} !==
     {ref_dut.w_dpc_valid,ref_dut.w_dpc_fs,ref_dut.w_dpc_raw}) begin
  if(errors<8) $display("Mismatch cycle=%0d new=%h old=%h",cycles,
      {nv,nrgb,nfs,nlast,nreq,nae,nag},{ov,orgb,ofs,olast,oreq,oae,oag});
  errors=errors+1;
 end
end
integer frame,x,y,p,gap,k,seed=32'h51703c21;
reg [31:0] random_bits;
initial begin
 repeat(4) @(negedge clk); rst=1; cfg=1;
 // Full frames cover every pixel mode, random RAW, EOL, SOF and input gaps.
 for(frame=0;frame<14;frame=frame+1) begin
  mode=frame%7;
  for(y=0;y<H;y=y+1) for(x=0;x<W;x=x+4) begin
   @(negedge clk);
   gv=1; gfs=(x==0 && y==0); glast=(x==W-4);
   for(p=0;p<4;p=p+1) gd[p*10+:10]=$random(seed);
   cmd=$random(seed); cmd_wr=(x==0 && y%5==0);
   @(negedge clk); gv=0; cmd_wr=0;
   random_bits=$random(seed); gap=4+(random_bits%8);
   // Deliberately toggle inactive data and frame-start during valid holes.
   repeat(gap) begin
    @(negedge clk); gd={$random(seed),$random(seed)};
    gfs=$random(seed); glast=$random(seed);
   end
  end
  repeat(W+40) @(negedge clk);
 end
 // Partial-frame restart, busy gearbox inputs and reset during every RAW stage.
 for(k=0;k<20000;k=k+1) begin
  @(negedge clk);
  random_bits=$random(seed);
  gv=random_bits[0]; gfs=random_bits[4:1]==0;
  glast=random_bits[5]; cfg=random_bits[6]; cmd_wr=random_bits[10:7]==0;
  mode=random_bits[13:11]; cmd=random_bits[31:16];
  gd={$random(seed),$random(seed)};
  if(k%997==3) begin
   #2; rst=0; #1;
   if({dut.w_dpc_valid,dut.w_dpc_fs,dut.w_dpc_raw} !== 12'd0 ||
      {ref_dut.w_dpc_valid,ref_dut.w_dpc_fs,ref_dut.w_dpc_raw} !== 12'd0)
    errors=errors+1;
  end
  if(k%997==4) rst=1;
 end
 @(negedge clk); gv=0; cmd_wr=0; gfs=0;
 repeat(W+50) @(negedge clk);
 if(errors==0 && cycles>30000 && valid_pixels>7000)
  $display("TEST_RESULT PASS proc_v30_cycle_equivalence cycles=%0d valid=%0d",cycles,valid_pixels);
 else $display("TEST_RESULT FAIL proc_v30_cycle_equivalence errors=%0d cycles=%0d valid=%0d",errors,cycles,valid_pixels);
 $finish;
end
endmodule
