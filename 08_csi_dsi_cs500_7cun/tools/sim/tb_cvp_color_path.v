`timescale 1ns/1ps
// Real gearbox -> RAW bypass -> window -> demosaic, with gaps and frame restart.
module tb_cvp_color_path;
localparam W=32,H=16;
reg clk=0,rst=0,grp_valid=0,grp_fs=0;
always #5 clk=~clk;
reg [39:0] group_data=0;
wire valid,fs;
wire [23:0] rgb;
wire gf_valid,gf_fs,gf_last;
wire [39:0] gf_data;
group_fifo transport(.I_wr_clk(clk),.I_wr_rst_n(rst),.I_wr_valid(grp_valid),.I_wr_data(group_data),.I_wr_tuser(grp_fs),.I_wr_tlast(1'b0),.I_rd_clk(clk),.I_rd_rst_n(rst),.O_rd_valid(gf_valid),.O_rd_data(gf_data),.O_rd_tuser(gf_fs),.O_rd_tlast(gf_last));
integer frame,x,y,p,slot=0,frame_seen=-1,errors=0,checked=0;
integer r_value,g_value,b_value,expected_r,expected_g,expected_b;
cvp_proc #(.IMG_W(W),.IMG_H(H)) dut(
 .i_clk(clk),.i_rst_n(rst),.i_mode(3'd0),.i_cam_cfg_done(1'b1),
 .i_cmd_ae(16'd560),.i_cmd_ae_wr(1'b0),.i_grp_valid(gf_valid),
 .i_grp_data(gf_data),.i_grp_frame_start(gf_fs),.i_grp_line_last(gf_last),
 .o_pix_valid(valid),.o_pix_rgb(rgb),.o_pix_frame_start(fs),.o_pix_line_last(),
 .o_ae_req(),.o_ae(),.o_ag());
function [9:0] raw_at(input integer cx,cy,fr);
begin
 if(fr==0)begin
  raw_at=(!cy[0]&&!cx[0])?100:(cy[0]&&cx[0])?900:500;
 end else begin
  raw_at=(!cy[0]&&!cx[0])?800:(cy[0]&&cx[0])?400:600;
 end
end
endfunction
always @(negedge clk) if(valid)begin
 if(fs)begin frame_seen=frame_seen+1;slot=0;end
 if(frame_seen>=0)begin
  if((slot%W)>=4 && (slot/W)>=4)begin
   checked=checked+1;
   expected_r=(frame_seen==0)?225:100;
   expected_g=(frame_seen==0)?125:150;
   expected_b=(frame_seen==0)?25:200;
   if(rgb!=={expected_r[7:0],expected_g[7:0],expected_b[7:0]})begin
    if(errors<8)$display("FAIL: frame=%0d xy=%0d,%0d rgb=%h expected=%0d/%0d/%0d",frame_seen,slot%W,slot/W,rgb,expected_r,expected_g,expected_b);
    errors=errors+1;
   end
  end
  slot=slot+1;
 end
end
initial begin
 #30;rst=1;
 // A partial stream precedes the next frame-start pulse. Address alignment must
 // use zero on the frame-start pixel itself, rather than the previous counters.
 repeat(3)begin
  @(negedge clk);grp_valid=1;grp_fs=0;group_data={4{10'd700}};
  @(negedge clk);grp_valid=0;repeat(8)@(negedge clk);
 end
 repeat(12)@(negedge clk);
 for(frame=0;frame<2;frame=frame+1)begin
  for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+4)begin
   @(negedge clk);grp_valid=1;grp_fs=(x==0&&y==0);
   for(p=0;p<4;p=p+1)group_data[p*10+:10]=raw_at(x+p,y,frame);
   @(negedge clk);grp_valid=0;grp_fs=0;
   repeat(6+(x%3))@(negedge clk);
  end
  repeat(12)@(negedge clk);
 end
 repeat(16)@(negedge clk);
 if(errors==0 && checked==672 && frame_seen==1)$display("TEST_RESULT PASS full_cvp_bayer_colour_path");
 else $display("TEST_RESULT FAIL full_cvp_bayer_colour_path errors=%0d checked=%0d frames=%0d",errors,checked,frame_seen+1);
 $finish;
end
endmodule
