`timescale 1ns/1ps
// Physical two-region scene: 80% dark pixels, 20% bright/clipped pixels.
// The fixed mean and clipping constraints are mutually incompatible.
module tb_v26_ae_contrast;
 reg clk=0,rst=0,frame_done=0;always #5 clk=~clk;
 reg [15:0] ne=500,ge=500;reg [10:0] nd=256,gd=256;
 reg [7:0] nm,gm;reg [31:0] nc,gc;reg np=0,gp=0,na=0,ga=0;
 wire nr,gr;wire [15:0] nx,gx;wire [10:0] nnext,gnext;wire [7:0] target;
 integer delay_n=0,delay_g=0,events_n=0,events_g=0,old_n,old_g,i,errors=0;
 integer dark=60,bright=300,yl,yh,model_n,model_g;
 reg [15:0] queued_n,queued_g;reg [10:0] queued_nd,queued_gd;
 cvp_ae_control dut(.clk(clk),.rst_n(rst),.i_frame_done(frame_done),.i_en(1'b1),.i_ready(1'b1),
  .i_busy(np),.i_cancel(1'b0),.i_applied(na),.i_apply_error(1'b0),.i_applied_digital_only(1'b0),.i_mean(nm),.i_clipped(nc),.i_samples(32'd1000),
  .i_exp(ne),.i_gain(8'd108),.i_dgain(nd),.o_valid(nr),.o_exp(nx),.o_gain(),.o_dgain(nnext),.o_pid_flags(),.o_target_mean(target));
 cvp_ae_control_v35_gold gold(.clk(clk),.rst_n(rst),.i_frame_done(frame_done),.i_en(1'b1),.i_ready(1'b1),
  .i_busy(gp),.i_cancel(1'b0),.i_applied(ga),.i_apply_error(1'b0),.i_mean(gm),.i_clipped(gc),.i_samples(32'd1000),
  .i_exp(ge),.i_gain(8'd108),.i_dgain(gd),.o_valid(gr),.o_exp(gx),.o_gain(),.o_dgain(gnext),.o_pid_flags());
 always @(posedge clk)begin #1;
  if(nr)begin queued_n=nx;queued_nd=nnext;np=1;delay_n=2;events_n=events_n+1;end
  if(gr)begin queued_g=gx;queued_gd=gnext;gp=1;delay_g=2;events_g=events_g+1;end
 end
 task image;reg had_n,had_g;begin
  @(negedge clk);had_n=np;had_g=gp;
  yl=(64'd1*dark*ne*nd)/(500*256);yh=(64'd1*bright*ne*nd)/(500*256);
  model_n=(80*(yl>255?255:yl)+20*(yh>255?255:yh))/100;nm=model_n;nc=(yl>=245?800:0)+(yh>=245?200:0);
  yl=(64'd1*dark*ge*gd)/(500*256);yh=(64'd1*bright*ge*gd)/(500*256);
  model_g=(80*(yl>255?255:yl)+20*(yh>255?255:yh))/100;gm=model_g;gc=(yl>=245?800:0)+(yh>=245?200:0);
  frame_done=1;@(negedge clk);frame_done=0;repeat(80)@(negedge clk);
  if(had_n)begin delay_n=delay_n-1;if(delay_n==0)begin ne=queued_n;nd=queued_nd;np=0;na=1;end end
  if(had_g)begin delay_g=delay_g-1;if(delay_g==0)begin ge=queued_g;gd=queued_gd;gp=0;ga=1;end end
  @(negedge clk);na=0;ga=0;
 end endtask
 initial begin
  #31;rst=1;repeat(360)image();old_n=events_n;old_g=events_g;
  repeat(120)image();
  $display("CONTRAST v35_steady_requests=%0d current_steady_requests=%0d E=%0d mean=%0d target=%0d clipped=%0d",events_g-old_g,events_n-old_n,ne,nm,target,nc);
  if(events_g-old_g<8||events_n!=old_n||target>=112||nc!=0||nm+8<target||nm>target+8)errors=errors+1;
  // Real scene change must release the protective target, not stay stuck dark.
  dark=10;bright=10;repeat(200)image();
  if(target!=112||nm<104||nm>120||ne!=1800||nd<=256)errors=errors+1;
  $display("SCENE_CHANGE E=%0d DG=%0d mean=%0d target=%0d",ne,nd,nm,target);
  if(errors==0)$display("TEST_RESULT PASS high_contrast_no_AE_limit_cycle_and_scene_release");
  else $display("TEST_RESULT FAIL contrast errors=%0d",errors);
  $finish;
 end
 initial begin #10000000;$display("TEST_RESULT FAIL contrast timeout");$finish;end
endmodule
