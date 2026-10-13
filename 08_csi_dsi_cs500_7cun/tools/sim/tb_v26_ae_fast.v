`timescale 1ns/1ps
// Independent delayed actuator: ACK/report may precede optical feedback by
// two full frames. Digital-only changes are visible on the acknowledged SOF.
module tb_v26_ae_fast;
 reg clk=0,rst=0,done=0,en=1,na=0,ga=0,nfail=0,digital_only=0,g_digital_only=0;
 always #5 clk=~clk;
 reg [15:0] ne=500,ge=500,nphysical=500,gphysical=500,nqueued,gqueued;
 reg [10:0] nd=256,gd=256,nqd,gqd;
 reg [7:0] nm,gm;reg np=0,gp=0;
 reg [31:0] samples=1000;
 wire nr,gr;wire [15:0] nx,gx;wire [10:0] nn,gn;
 integer light=40,noise=0,ndelay=0,gdelay=0,nopt=0,gopt=0;
 integer nvalue,gvalue,nfirst=0,gfirst=0,frame_no=0,nevents=0,gevents=0;
 integer errors=0,checks=0,k,before_n,before_g,nstep,gstep;
 reg apply_auto=1;
 cvp_ae_control dut(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),.i_ready(1'b1),
  .i_busy(np),.i_cancel(1'b0),.i_applied(na),.i_apply_error(nfail),.i_applied_digital_only(digital_only),
  .i_mean(nm),.i_clipped(32'd0),.i_samples(samples),.i_exp(ne),.i_gain(8'd108),.i_dgain(nd),
  .o_valid(nr),.o_exp(nx),.o_gain(),.o_dgain(nn),.o_pid_flags(),.o_target_mean());
 cvp_ae_control_v37_gold gold(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),.i_ready(1'b1),
  .i_busy(gp),.i_cancel(1'b0),.i_applied(ga),.i_apply_error(1'b0),.i_applied_digital_only(g_digital_only),
  .i_mean(gm),.i_clipped(32'd0),.i_samples(samples),.i_exp(ge),.i_gain(8'd108),.i_dgain(gd),
  .o_valid(gr),.o_exp(gx),.o_gain(),.o_dgain(gn),.o_pid_flags(),.o_target_mean());
 always @(posedge clk)begin #1;if(rst)begin
  if(nr)begin
   if(np||nx<62||nx>1800||nn<256||nn>1024||(nn>256&&nx!=1800))begin
    errors=errors+1;$display("FAIL allocation or overlapping request");end
   nqueued=nx;nqd=nn;np=1;ndelay=2;nevents=nevents+1;
  end
  if(gr)begin gqueued=gx;gqd=gn;gp=1;gdelay=2;gevents=gevents+1;end
 end end
 task check;input ok;input [511:0] label;begin
  checks=checks+1;if(!ok)begin errors=errors+1;$display("FAIL %0s frame=%0d E=%0d DG=%0d mean=%0d",label,frame_no,ne,nd,nm);end
 end endtask
 function [7:0] sat;input integer val;begin sat=val<0?0:val>255?255:val;end endfunction
 task reset_case;begin
  @(negedge clk);rst=0;done=0;en=1;na=0;ga=0;nfail=0;digital_only=0;g_digital_only=0;
  ne=500;ge=500;nphysical=500;gphysical=500;nd=256;gd=256;
  np=0;gp=0;ndelay=0;gdelay=0;nopt=0;gopt=0;nevents=0;gevents=0;
  samples=1000;noise=0;light=40;nfirst=0;gfirst=0;frame_no=0;apply_auto=1;
  repeat(4)@(negedge clk);rst=1;repeat(4)@(negedge clk);
 end endtask
 task frame;input integer override_mean;reg had_n,had_g;begin
  @(negedge clk);had_n=np;had_g=gp;
  nvalue=(64'd1*nphysical*nd*light)/(500*256);
  gvalue=(64'd1*gphysical*gd*light)/(500*256);
  nm=override_mean<0?sat(nvalue+noise):override_mean;
  gm=override_mean<0?sat(gvalue+noise):override_mean;
  frame_no=frame_no+1;
  if(override_mean<0&&nvalue>=104&&nvalue<=120&&nfirst==0)nfirst=frame_no;
  if(override_mean<0&&gvalue>=104&&gvalue<=120&&gfirst==0)gfirst=frame_no;
  done=1;@(negedge clk);done=0;repeat(80)@(negedge clk);
  // Two measured frames remain stale after an exposure ACK.
  if(nopt>0)begin nopt=nopt-1;if(nopt==0)nphysical=ne;end
  if(gopt>0)begin gopt=gopt-1;if(gopt==0)gphysical=ge;end
  if(apply_auto&&had_n)begin ndelay=ndelay-1;if(ndelay==0)begin
   digital_only=nqueued==ne;ne=nqueued;nd=nqd;np=0;na=1;
   if(!digital_only)nopt=2;
  end end
  if(apply_auto&&had_g)begin gdelay=gdelay-1;if(gdelay==0)begin
   g_digital_only=gqueued==ge;
   if(!g_digital_only)gopt=2;ge=gqueued;gd=gqd;gp=0;ga=1;
  end end
  @(negedge clk);na=0;ga=0;digital_only=0;g_digital_only=0;
 end endtask
 initial begin
  reset_case();repeat(240)frame(-1);
  // User-selected gains need not improve every scene. Check bounded
  // convergence/stability and report the actual same-plant comparison.
  check(nfirst>0&&nfirst<100&&gfirst>0,"631 dark converges with stale exposure feedback");
  before_n=nevents;repeat(100)frame(-1);check(nevents==before_n,"dark equilibrium has no pumping");
  $display("FAST_COMPARE dark new_frames=%0d v37_frames=%0d E=%0d DG=%0d mean=%0d",nfirst,gfirst,ne,nd,nm);
  light=160;nfirst=0;gfirst=0;frame_no=0;repeat(160)frame(-1);
  check(nfirst>0&&nfirst<100&&gfirst>0,"631 bright converges with stale exposure feedback");
  before_n=nevents;repeat(100)frame(-1);check(nevents==before_n,"bright equilibrium has no pumping");
  $display("FAST_COMPARE bright new_frames=%0d v37_frames=%0d E=%0d DG=%0d mean=%0d",nfirst,gfirst,ne,nd,nm);
  reset_case();light=10;repeat(300)frame(-1);
  check(nfirst>0&&nfirst<160&&gfirst>0&&ne==1800&&nd>256,"631 very dark converges using digital-only SOF feedback");
  before_n=nevents;repeat(100)frame(-1);check(nevents==before_n,"digital equilibrium has no pumping");
  $display("FAST_COMPARE very_dark new_frames=%0d v37_frames=%0d E=%0d DG=%0d mean=%0d",nfirst,gfirst,ne,nd,nm);
  before_n=nevents;repeat(80)begin noise=6;frame(-1);noise=-6;frame(-1);end
  check(nevents==before_n,"steady digital exposure rejects alternating noise");
  light=80;noise=0;nfirst=0;gfirst=0;frame_no=0;repeat(200)frame(-1);
  check(nfirst>0&&nd==256&&ne<1800&&nm>=104&&nm<=120,"bright recovery removes digital gain first");
  $display("FAST_COMPARE recovery new_frames=%0d v37_frames=%0d",nfirst,gfirst);

  reset_case();apply_auto=0;frame(88);check(nevents==0,"large error needs two measurements");
  frame(88);check(nevents==1,"24-code error uses fresh pair");
  repeat(10)frame(88);check(nevents==1,"no update before actuator confirmation");
  np=0;nfail=1;@(negedge clk);nfail=0;repeat(4)@(negedge clk);
  frame(88);check(nevents==1,"failure requires a new pair");frame(88);check(nevents==2,"failure can recover");
  reset_case();apply_auto=0;repeat(3)frame(89);check(nevents==0,"near target retains four-frame filtering");
  frame(89);check(nevents==1,"fourth near-target frame drives control");
  reset_case();apply_auto=0;repeat(80)begin frame(80);frame(144);end
  check(nevents==0,"two-frame fast path rejects alternating brightness");
  reset_case();apply_auto=0;frame(20);samples=0;frame(20);samples=1000;
  frame(20);check(nevents==0,"empty frame discards partial pair");frame(20);check(nevents==1,"fresh pair restarts after empty frame");

  // Prove the acknowledgement type controls settling, using hostile stale
  // brightness to catch any premature exposure update.
  reset_case();apply_auto=0;ne=1800;nphysical=1800;nd=256;repeat(2)frame(20);
  check(nevents==1&&nn>256&&nx==1800,"digital-only request at exposure ceiling");
  np=0;nd=nqd;digital_only=1;na=1;@(negedge clk);na=0;digital_only=0;
  frame(20);check(nevents==1,"digital-only needs a fresh pair, no blind wait");
  frame(20);check(nevents==2,"digital-only can update on second new frame");
  reset_case();apply_auto=0;repeat(2)frame(20);np=0;ne=nqueued;na=1;
  @(negedge clk);na=0;repeat(2)frame(255);frame(112);
  check(nevents==1,"exposure acknowledgement discards two hostile stale frames");
  repeat(3)frame(112);check(nevents==1,"fresh neutral exposure prevents erroneous reversal");
  if(errors==0)$display("TEST_RESULT PASS adaptive_two_four_frame_PID_digital_only_no_wait checks=%0d",checks);
  else $display("TEST_RESULT FAIL adaptive PID errors=%0d checks=%0d",errors,checks);
  $finish;
 end
 initial begin #10000000;$display("TEST_RESULT FAIL fast PID timeout");$finish;end
endmodule
