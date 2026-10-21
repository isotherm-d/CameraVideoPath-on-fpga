`timescale 1ns/1ps
// Independent static-light sensor models, two-frame actuator feedback delay.
module tb_v26_ae_pid #(parameter KD=1);
reg clk=0,rst=0,en=1,done=0,cancel=0,applied=0,failed=0;
always #5 clk=~clk;
reg [15:0] exposure=500,old_exp=500;
reg [10:0] dgain=256;
reg [7:0] old_gain=108;
reg [15:0] lux=40;
reg [31:0] clips=0,samples=1000;
reg [7:0] mean,old_mean;
wire req,old_req;wire [15:0] desired,old_desired;
wire [7:0] ag,old_ag,flags;wire [10:0] desired_dg;
reg pending=0,old_pending=0,fail_next=0,auto_apply=1;
reg [15:0] queued_exp,old_queued_exp;reg [10:0] queued_dg;
reg [7:0] old_queued_gain;integer delay_count=0,old_delay=0;
integer errors=0,checks=0,events=0,old_events=0,n,first_new,first_old,model_value,old_value;
integer frame_no=0;
cvp_ae_control #(.KD_Q10(KD)) dut(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),.i_ready(1'b1),
 .i_busy(pending),.i_cancel(cancel),.i_applied(applied),.i_apply_error(failed),.i_applied_digital_only(1'b0),
 .i_mean(mean),.i_clipped(clips),.i_samples(samples),.i_exp(exposure),.i_gain(8'd108),.i_dgain(dgain),
 .o_valid(req),.o_exp(desired),.o_gain(ag),.o_dgain(desired_dg),.o_pid_flags(flags));
cvp_ae_control_v33_gold baseline(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),.i_ready(1'b1),
 .i_busy(old_pending),.i_mean(old_mean),.i_clipped(clips),.i_samples(samples),
 .i_exp(old_exp),.i_gain(old_gain),.o_valid(old_req),.o_exp(old_desired),.o_gain(old_ag));
function integer analog_q8;input integer index;integer x;begin
 x=index-16;analog_q8=((32+(x%32))*8)<<(x/32);
end endfunction
always @(posedge clk)begin
 #1;
 if(rst)begin
  if(dut.integral>512||dut.integral< -512)begin errors=errors+1;$display("FAIL integral bounds");end
  if(req)begin
   if(pending||desired<62||desired>1800||desired_dg<256||desired_dg>1024||
      ag!=108||(desired_dg>256&&desired!=1800))begin
    errors=errors+1;$display("FAIL allocation E=%0d DG=%0d AG=%0d pending=%b",desired,desired_dg,ag,pending);
   end
   queued_exp=desired;queued_dg=desired_dg;pending=1;delay_count=2;events=events+1;
  end
  if(old_req)begin old_queued_exp=old_desired;old_queued_gain=old_ag;old_pending=1;old_delay=2;old_events=old_events+1;end
 end
end
task check;input condition;input [511:0] msg;begin
 checks=checks+1;if(!condition)begin errors=errors+1;$display("FAIL %0s E=%0d DG=%0d events=%0d",msg,exposure,dgain,events);end
end endtask
task reset_case;begin
 @(negedge clk);rst=0;done=0;cancel=0;applied=0;failed=0;en=1;
 exposure=500;dgain=256;old_exp=500;old_gain=108;pending=0;old_pending=0;
 lux=40;clips=0;samples=1000;events=0;old_events=0;frame_no=0;first_new=0;first_old=0;
 fail_next=0;auto_apply=1;
 repeat(4)@(negedge clk);rst=1;repeat(4)@(negedge clk);
end endtask
task frame;input integer manual_mean;reg had_pending,had_old_pending;begin
 @(negedge clk);had_pending=pending;had_old_pending=old_pending;
 model_value=(64'd1*exposure*dgain*lux)/(500*256);
 old_value=(64'd1*old_exp*analog_q8(old_gain)*lux)/(500*1920);
 mean=manual_mean<0?(model_value>255?255:model_value):manual_mean;
 old_mean=manual_mean<0?(old_value>255?255:old_value):manual_mean;
 done=1;frame_no=frame_no+1;
 if(manual_mean<0&&model_value>=104&&model_value<=120&&first_new==0)first_new=frame_no;
 if(manual_mean<0&&old_value>=104&&old_value<=120&&first_old==0)first_old=frame_no;
 @(negedge clk);done=0;
 repeat(64)@(negedge clk);
 if(auto_apply&&had_pending)begin
  delay_count=delay_count-1;
  if(delay_count==0)begin
   pending=0;
   if(fail_next)begin failed=1;fail_next=0;end
   else begin exposure=queued_exp;dgain=queued_dg;applied=1;end
  end
 end
 if(auto_apply&&had_old_pending)begin
  old_delay=old_delay-1;if(old_delay==0)begin old_pending=0;old_exp=old_queued_exp;old_gain=old_queued_gain;end
 end
 @(negedge clk);applied=0;failed=0;
end endtask
integer stable_events,first_bright,before_events;
initial begin
 reset_case();
 for(n=0;n<400;n=n+1)frame(-1);
 check(first_new>0&&first_old>0&&first_new*2<first_old,"dark step converges at least twice as fast as v33");
 check(model_value>=104&&model_value<=120&&dgain==256,"exposure-only convergence holds unity digital gain");
 stable_events=events;repeat(80)frame(-1);check(events==stable_events,"steady light does not pump");
 $display("CONVERGENCE dark PID_frames=%0d v33_frames=%0d PID_E=%0d DG=%0d",first_new,first_old,exposure,dgain);
 lux=160;first_bright=0;
 for(n=0;n<160;n=n+1)begin frame(-1);if(model_value>=104&&model_value<=120&&first_bright==0)first_bright=n+1;end
 check(first_bright>0&&first_bright<100,"bright step converges with delayed feedback");
 stable_events=events;repeat(80)frame(-1);check(events==stable_events,"bright-step equilibrium holds");
 $display("CONVERGENCE bright PID_frames=%0d PID_E=%0d DG=%0d",first_bright,exposure,dgain);

 reset_case();lux=10;for(n=0;n<240;n=n+1)frame(-1);
 check(exposure==1800&&dgain>700&&dgain<900&&model_value>=104&&model_value<=120,"digital gain is used only beyond maximum exposure");
 stable_events=events;repeat(40)frame(-1);check(events==stable_events,"digital-gain equilibrium holds");
 $display("CONVERGENCE very_dark PID_frames=%0d PID_E=%0d DG=%0d",first_new,exposure,dgain);
 lux=80;for(n=0;n<200;n=n+1)frame(-1);
 check(dgain==256&&exposure<1800&&model_value>=104&&model_value<=120,"bright recovery removes digital gain before shortening allocated exposure");

 reset_case();lux=0;for(n=0;n<240;n=n+1)frame(-1);
 check(exposure==1800&&dgain==1024,"upper limits reached without overflow");
 stable_events=events;repeat(40)frame(-1);check(events==stable_events,"no redundant requests at upper limit");
 check(dut.integral==0,"upper saturation does not wind up integral");
 reset_case();exposure=62;lux=5000;repeat(40)frame(-1);
 check(exposure==62&&dgain==256&&events==0,"lower limit holds without requests or windup");

 reset_case();exposure=500;lux=100;
 for(n=0;n<40;n=n+1)begin frame(80);frame(144);end
 check(events==0,"four-frame averaging rejects alternating brightness");
 reset_case();repeat(4)frame(104);repeat(4)frame(120);
 check(events==0,"inclusive deadband unchanged");
 reset_case();clips=51;repeat(4)frame(112);
 check(events==1&&queued_exp<500,"persistent highlights lower total exposure");
 reset_case();samples=0;repeat(8)frame(20);check(events==0,"empty statistics never drive PID");
 samples=1000;frame(20);check(events==0,"two new frames needed for large error after empty statistics");
 frame(20);check(events==1,"controller restarts on fresh statistics");

 reset_case();auto_apply=0;repeat(4)frame(80);
 check(events==1&&dut.integral==0&&dut.wait_apply,"integral is not committed before feedback");
 repeat(12)frame(80);check(events==1,"no second request before actuator confirmation");
 pending=0;failed=1;@(negedge clk);failed=0;repeat(4)@(negedge clk);
 check(dut.integral==0&&!dut.wait_apply,"failed write leaves integral uncommitted");
 before_events=events;repeat(4)frame(80);check(events==before_events+1,"failed write can retry from measured parameters");
 cancel=1;@(negedge clk);cancel=0;pending=0;repeat(4)@(negedge clk);
 check(!dut.wait_apply&&dut.integral==0,"manual control cancels pending PID state");
 exposure=800;dgain=256;applied=1;@(negedge clk);applied=0;repeat(4)@(negedge clk);
 before_events=events;repeat(2)frame(20);frame(20);
 check(events==before_events,"manual commit discards two stale frames before collecting fresh pair");
 frame(20);check(events==before_events+1,"PID resumes from confirmed manual exposure");
 en=0;repeat(12)frame(0);before_events=events;repeat(8)frame(0);
 check(events==before_events,"disabled AE leaves manual settings alone");
 if(errors==0)$display("TEST_RESULT PASS PID_exposure_first_digital_gain_delay_clamps checks=%0d",checks);
 else $display("TEST_RESULT FAIL PID errors=%0d checks=%0d",errors,checks);
 $finish;
end
initial begin #10000000;$display("TEST_RESULT FAIL PID timeout");$finish;end
endmodule
