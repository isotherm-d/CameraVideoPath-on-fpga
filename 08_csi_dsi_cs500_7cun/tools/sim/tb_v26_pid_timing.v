`timescale 1ns/1ps
// Compare accepted commands and committed history, allowing computation latency.
// Both actuators receive a common two-frame callback after requests are paired.
module tb_v26_pid_timing;
 wire [5:0] finished;wire [31:0] e0,e2,e32,emax,emin,emix;
 cvp_pid_timing_checker #(.KD(0)) c0(.finished(finished[0]),.errors(e0));
 cvp_pid_timing_checker #(.KD(2)) c2(.finished(finished[1]),.errors(e2));
 cvp_pid_timing_checker #(.KD(32)) c32(.finished(finished[2]),.errors(e32));
 cvp_pid_timing_checker #(.KP(32767),.KI(32767),.KD(32767)) cmax(.finished(finished[3]),.errors(emax));
 cvp_pid_timing_checker #(.KP(-32768),.KI(-32768),.KD(-32768)) cmin(.finished(finished[4]),.errors(emin));
 cvp_pid_timing_checker #(.KP(7),.KI(-5),.KD(32767)) cmix(.finished(finished[5]),.errors(emix));
 initial begin
  wait(&finished);#10;
  if(e0+e2+e32+emax+emin+emix==0)$display("TEST_RESULT PASS PID_v34_timing_equivalence KD=0,2,32 signed16_extremes");
  else $display("TEST_RESULT FAIL PID_v34_timing_equivalence errors=%0d",e0+e2+e32+emax+emin+emix);
  $finish;
 end
 initial begin #20000000;$display("TEST_RESULT FAIL PID timing equivalence timeout");$finish;end
endmodule

module cvp_pid_timing_checker #(parameter KP=4,KI=1,KD=0)(output reg finished=0,output reg [31:0] errors=0);
 reg clk=0,rst=0,en=1,ready=1,busy=0,cancel=0,done=0,applied=0,failed=0;
 always #5 clk=~clk;
 reg [7:0] mean=112,gain=108;reg [31:0] clips=0,samples=1000;
 reg [15:0] exposure=500;reg [10:0] dgain=256;
 wire n_req,g_req;wire [15:0] n_exp,g_exp;wire [10:0] n_dgain,g_dgain;
 wire [7:0] n_gain,g_gain,n_flags,g_flags;
 // Historical v34-to-v35 timing-only regression. Adaptive AE is tested separately.
 cvp_ae_control_v35_gold #(.KP_Q10(KP),.KI_Q10(KI),.KD_Q10(KD)) dut(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),
  .i_ready(ready),.i_busy(busy),.i_cancel(cancel),.i_applied(applied),.i_apply_error(failed),
  .i_mean(mean),.i_clipped(clips),.i_samples(samples),.i_exp(exposure),.i_gain(gain),.i_dgain(dgain),
  .o_valid(n_req),.o_exp(n_exp),.o_gain(n_gain),.o_dgain(n_dgain),.o_pid_flags(n_flags));
 cvp_ae_control_v34_gold #(.KP_Q10(KP),.KI_Q10(KI),.KD_Q10(KD)) gold(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),
  .i_ready(ready),.i_busy(busy),.i_cancel(cancel),.i_applied(applied),.i_apply_error(failed),
  .i_mean(mean),.i_clipped(clips),.i_samples(samples),.i_exp(exposure),.i_gain(gain),.i_dgain(dgain),
  .o_valid(g_req),.o_exp(g_exp),.o_gain(g_gain),.o_dgain(g_dgain),.o_pid_flags(g_flags));
 integer n_count=0,g_count=0,paired=0,callback_delay=0,checks=0,frame_no=0,total_commands=0;
 integer failures=0,cancels=0,upper=0,lower=0,highlight_frames=0,zero_frames=0;
 reg [15:0] n_queued_exp,g_queued_exp;reg [10:0] n_queued_dgain,g_queued_dgain;
 reg [7:0] n_queued_gain,g_queued_gain;reg pending=0,fail_next=0,check_flags=1;
 reg [31:0] random_state=32'h74ac1059;
 integer k,j,t,lux=40,model_mean,before_commands,abort_cycles;
 reg had_pending;
 always @(posedge clk)begin
  #1;
  if(rst)begin
   if(n_req)begin n_count=n_count+1;n_queued_exp=n_exp;n_queued_dgain=n_dgain;n_queued_gain=n_gain;end
   if(g_req)begin g_count=g_count+1;g_queued_exp=g_exp;g_queued_dgain=g_dgain;g_queued_gain=g_gain;end
  end
 end
 task check;input condition;input [511:0] msg;begin
  checks=checks+1;
  if(!condition)begin
   errors=errors+1;
   if(errors<15)$display("FAIL timing KD=%0d frame=%0d %0s new=%0d/%0d/%0d old=%0d/%0d/%0d req=%0d/%0d",
    KD,frame_no,msg,n_exp,n_dgain,n_gain,g_exp,g_dgain,g_gain,n_count,g_count);
  end
 end endtask
 task compare_history;begin
  check({dut.integral,dut.derivative,dut.previous_valid}===
        {gold.integral,gold.derivative,gold.previous_valid},"committed integral/derivative validity sequence");
  if(dut.previous_valid&&gold.previous_valid)
   check({dut.previous_error,dut.previous_mean}==={gold.previous_error,gold.previous_mean},
         "committed error/mean sequence while history valid");
  check({dut.frames,dut.settle,dut.wait_apply}==={gold.frames,gold.settle,gold.wait_apply},
        "frame averaging, settle, and pending feedback");
  if(check_flags)check(n_flags[7:1]===g_flags[7:1],"settled PID flags excluding calculation busy");
 end endtask
 task pair_requests;begin
  check(n_count==g_count,"accepted request count");
  if(n_count!=paired&&g_count!=paired)begin
   check(n_count==paired+1&&g_count==paired+1,"at most one command per feedback interval");
   check({n_queued_exp,n_queued_dgain,n_queued_gain}==={g_queued_exp,g_queued_dgain,g_queued_gain},
         "exact exposure/digital/analogue command sequence");
   check(!pending,"no second command before common callback");
   check(n_queued_exp>=62&&n_queued_exp<=1800&&n_queued_dgain>=256&&n_queued_dgain<=1024&&
         (n_queued_dgain==256||n_queued_exp==1800),"exposure priority and bounds");
   paired=n_count;pending=1;busy=1;callback_delay=2;
   total_commands=total_commands+1;
  end
 end endtask
 task reset_case;begin
  @(negedge clk);rst=0;en=1;ready=1;busy=0;cancel=0;done=0;applied=0;failed=0;
  exposure=500;dgain=256;gain=108;mean=112;clips=0;samples=1000;
  n_count=0;g_count=0;paired=0;pending=0;fail_next=0;callback_delay=0;frame_no=0;check_flags=1;
  repeat(4)@(negedge clk);rst=1;repeat(4)@(negedge clk);
 end endtask
 task frame;input integer m;input [31:0] c,s;begin
  @(negedge clk);had_pending=pending;mean=m;clips=c;samples=s;done=1;frame_no=frame_no+1;
  if(c*20>s&&s!=0)highlight_frames=highlight_frames+1;
  if(s==0)zero_frames=zero_frames+1;
  @(negedge clk);done=0;repeat(96)@(negedge clk);
  pair_requests();compare_history();
  if(had_pending)begin
   callback_delay=callback_delay-1;
   if(callback_delay==0)begin
    pending=0;busy=0;
    if(fail_next)begin failed=1;fail_next=0;failures=failures+1;end
    else begin exposure=n_queued_exp;dgain=n_queued_dgain;gain=n_queued_gain;applied=1;end
    @(negedge clk);applied=0;failed=0;repeat(4)@(negedge clk);compare_history();
   end
  end
 end endtask
 task manual;input [15:0] e;input [10:0] d;input [7:0] a;begin
  @(negedge clk);cancel=1;cancels=cancels+1;
  @(negedge clk);cancel=0;pending=0;busy=0;exposure=e;dgain=d;gain=a;applied=1;
  @(negedge clk);applied=0;repeat(4)@(negedge clk);compare_history();
 end endtask
 // Abort both implementations while the fourth sample is being calculated.
 // A late abort may arrive after v34 already issued its faster request. It
 // receives no callback. Check the current pipeline discards the calculation,
 // then cancel both histories and compare commands from four fresh frames.
 task abort_compute;input integer reason;input integer stage;begin
  reset_case();repeat(3)frame(20,0,1000);
  @(negedge clk);mean=20;done=1;frame_no=frame_no+1;
  @(negedge clk);done=0;abort_cycles=0;
  while(dut.state!=stage&&abort_cycles<24)begin @(negedge clk);abort_cycles=abort_cycles+1;end
  check(dut.state==stage,"target calculation stage reached for abort");
  case(reason)
   0:cancel=1;
   1:busy=1;
   2:en=0;
   3:ready=0;
   4:begin applied=1;exposure=700;end
  endcase
  @(negedge clk);cancel=0;busy=0;en=1;ready=1;applied=0;
  repeat(96)@(negedge clk);
  check(n_count==0,"new calculation abort cannot issue stale command");
  check(dut.integral==0&&gold.integral==0,"abort never commits unconfirmed integral");
  cancel=1;@(negedge clk);cancel=0;
  repeat(4)@(negedge clk);n_count=0;g_count=0;paired=0;pending=0;busy=0;check_flags=0;
  compare_history();
  repeat(3)frame(20,0,1000);check(n_count==0&&g_count==0,"abort discards old averaging window");
  frame(20,0,1000);repeat(8)frame(20,0,1000);
 end endtask
 initial begin
  reset_case();
  // A common physical model applies successful requests two later frames.
  for(k=0;k<900;k=k+1)begin
   if(k<250)lux=40;else if(k<500)lux=10;else if(k<700)lux=180;else lux=0;
   model_mean=(64'd1*exposure*dgain*lux)/(500*256);
   frame(model_mean>255?255:model_mean,0,1000);
  end
  if(KP==4&&KI==1)check(exposure==1800&&dgain==1024,"upper saturation reached in sensor model");upper=upper+1;
  manual(62,256,143);repeat(48)frame(255,0,1000);
  check(exposure==62&&dgain==256,"lower saturation holds manual analogue value");lower=lower+1;
  manual(500,256,16);repeat(24)frame(112,51,1000);
  // Disable / not-ready / manual commit while a transaction is pending.
  reset_case();repeat(4)frame(10,0,1000);
  if(KP==4&&KI==1)check(pending,"dark request pending before cancellation");manual(800,256,90);
  repeat(7)frame(112,0,1000);check(!pending,"manual reset restarts fresh averaging");
  en=0;repeat(5)frame(0,0,1000);en=1;repeat(5)frame(80,0,1000);
  ready=0;repeat(3)frame(255,0,1000);ready=1;repeat(12)frame(80,0,1000);
  // Failed actuator writes do not commit the held integral/derivative.
  reset_case();fail_next=1;repeat(18)frame(70,0,1000);
  if(KP==4&&KI==1)check(failures>0,"failed-write callback exercised");
  // Deterministic random windows include large counters, empty samples,
  // exact highlight threshold, sign reversals and a range of analogue values.
  reset_case();
  for(k=0;k<1200;k=k+1)begin
   random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
   if(k%101==0)manual(62+(random_state%1739),256+(random_state%769),16+(random_state%128));
   if(k%37==0)fail_next=1;
   case(k%11)
    0:frame(random_state[7:0],0,0);
    1:frame(random_state[15:8],32'h3fffffff,32'hffffffff);
    2:frame(random_state[7:0],50,1000);
    3:frame(random_state[15:8],51,1000);
    default:frame(random_state[7:0],random_state[9:0],65535);
   endcase
  end
  for(t=2;t<=8;t=t+1)for(j=0;j<5;j=j+1)abort_compute(j,t);
  check(upper>0&&lower>0&&highlight_frames>0&&zero_frames>0&&cancels>0,
        "upper/lower/highlight/empty/manual coverage");
  $display("PID_TIMING_EQUIV KP=%0d KI=%0d KD=%0d checks=%0d commands=%0d failures=%0d cancel=%0d highlighted=%0d empty=%0d errors=%0d",
           KP,KI,KD,checks,total_commands,failures,cancels,highlight_frames,zero_frames,errors);
  finished=1;
 end
endmodule
