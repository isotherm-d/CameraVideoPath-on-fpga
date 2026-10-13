`timescale 1ns/1ps
// Frozen v33 smoothing baseline; current PID has separate closed-loop tests.
module tb_v26_ae_smooth;
reg clk=0,rst=0,en=1,ready=1,busy=0,done=0;
always #5 clk=~clk;
reg [7:0] mean=112,gain=108;
reg [15:0] exp=500;
reg [31:0] clips=0,samples=1000;
wire request;wire [15:0] desired;wire [7:0] dg;
cvp_ae_control_v33_gold dut(.clk(clk),.rst_n(rst),.i_frame_done(done),.i_en(en),
 .i_ready(ready),.i_busy(busy),.i_mean(mean),.i_clipped(clips),.i_samples(samples),
 .i_exp(exp),.i_gain(gain),.o_valid(request),.o_exp(desired),.o_gain(dg));
integer errors=0,events=0,checks=0;
reg last_request=0;
always @(posedge clk) begin
 #1;
 if(rst) begin
  if(request && last_request) begin errors=errors+1;$display("FAIL request not a single pulse");end
  if(request) begin
   if(desired<62 || desired>1800 || dg<16 || dg>143 ||
      (dg>gain ? dg-gain : gain-dg)>2 ||
      (desired>exp ? desired-exp : exp-desired)>((exp>>5)==0?1:(exp>>5))) begin
    errors=errors+1;$display("FAIL bounds/step exp=%0d->%0d gain=%0d->%0d",exp,desired,gain,dg);
   end
   events=events+1;exp=desired;gain=dg;
  end
 end
 last_request=request;
end
task check;input condition;input [511:0] message;begin
 checks=checks+1;
 if(!condition)begin errors=errors+1;$display("FAIL %0s",message);end
end endtask
task reset_case;begin
 @(negedge clk);rst=0;done=0;en=1;ready=1;busy=0;
 mean=112;clips=0;samples=1000;exp=500;gain=108;
 repeat(4)@(negedge clk);rst=1;events=0;last_request=0;
 repeat(4)@(negedge clk);
end endtask
task frame;input [7:0] brightness;input [31:0] clipped,count;begin
 @(negedge clk);mean=brightness;clips=clipped;samples=count;done=1;
 @(negedge clk);done=0;repeat(10)@(negedge clk);
end endtask
task frames;input integer n;input [7:0] brightness;input [31:0] clipped,count;
integer j;begin for(j=0;j<n;j=j+1)frame(brightness,clipped,count);end endtask

// Independent static, linear sensor model. A gain index of 16 is 1x;
// indices 16..47 have gain = 1 + (index-16)/32 (SC500GainTbl).
reg plant_en=0,plant_done=0;
reg [15:0] new_exp=1800,old_exp=1800;
reg [7:0] new_gain=16,old_gain=16;
reg [15:0] plant_level=100;
wire [7:0] new_mean=(plant_level*new_exp*(new_gain+16))/(1800*32);
wire [7:0] old_mean=(plant_level*old_exp*(old_gain+16))/(1800*32);
wire new_req,old_req;wire [15:0] new_desired,old_desired;wire [7:0] new_dg,old_dg;
integer new_events=0,old_events=0;
cvp_ae_control_v33_gold smooth_plant(.clk(clk),.rst_n(rst),.i_frame_done(plant_done),.i_en(plant_en),
 .i_ready(1'b1),.i_busy(1'b0),.i_mean(new_mean),.i_clipped(32'd0),.i_samples(32'd1000),
 .i_exp(new_exp),.i_gain(new_gain),.o_valid(new_req),.o_exp(new_desired),.o_gain(new_dg));
cvp_ae_v31_gold old_plant(.clk(clk),.rst_n(rst),.i_frame_done(plant_done),.i_en(plant_en),
 .i_ready(1'b1),.i_busy(1'b0),.i_mean(old_mean),.i_clipped(32'd0),.i_samples(32'd1000),
 .i_exp(old_exp),.i_gain(old_gain),.o_valid(old_req),.o_exp(old_desired),.o_gain(old_dg));
always @(posedge clk)begin
 #2;
 if(rst&&plant_en)begin
  if(new_req)begin new_exp=new_desired;new_gain=new_dg;new_events=new_events+1;end
  if(old_req)begin old_exp=old_desired;old_gain=old_dg;old_events=old_events+1;end
 end
end
integer k;
initial begin
 reset_case();frames(3,70,0,1000);check(events==0,"need four fresh frames");
 frame(70,0,1000);check(events==1&&exp==515&&gain==108,"500 increases by 15 half-lines");
 frames(2,70,0,1000);check(events==1,"two settling frames discarded");
 frames(3,70,0,1000);check(events==1,"four fresh frames after settling");
 frame(70,0,1000);check(events==2&&exp==531,"second small exposure step");

 reset_case();
 for(k=0;k<40;k=k+1)begin frame(80,0,1000);frame(144,0,1000);end
 check(events==0,"alternating brightness averages to 112 without pumping");
 reset_case();frames(3,80,0,1000);frame(208,0,1000);
 check(events==0,"latest bright frame does not override four-frame mean");
 reset_case();frames(4,104,0,1000);frames(4,120,0,1000);
 check(events==0,"inclusive deadband boundaries");
 reset_case();frame(103,0,1000);frames(3,104,0,1000);
 check(events==1,"fractional average below 104 is not rounded into deadband");

 reset_case();frame(112,100,1000);frames(3,112,0,1000);
 check(events==0,"one frame with 10 percent highlights averages below five percent");
 reset_case();frames(4,112,50,1000);check(events==0,"exactly five percent highlights holds");
 frames(4,112,51,1000);check(events==1&&gain==106,"persistent highlights reduce gain by two");
 reset_case();frames(4,112,32'h0ccccccc,32'hffffffff);
 check(events==0,"full-width accumulated counts below five percent do not overflow");
 frames(4,112,32'h0ccccccd,32'hffffffff);
 check(events==1,"full-width count just above five percent is detected");

 reset_case();frames(3,70,0,1000);frame(70,0,0);frames(3,70,0,1000);
 check(events==0,"empty frame invalidates partial averaging window");
 frame(70,0,1000);check(events==1,"four nonempty frames after invalid frame");
 reset_case();frames(3,70,0,1000);busy=1;frames(4,70,0,1000);
 check(events==0,"no command while sensor busy");
 busy=0;frames(3,112,0,1000);check(events==0,"busy discarded previous dark window");
 frame(112,0,1000);check(events==0,"fresh neutral window after busy");
 reset_case();frames(4,70,0,1000);busy=1;frames(8,200,0,1000);busy=0;
 frames(2,200,0,1000);frames(4,112,0,1000);
 check(events==1,"settling starts after busy ends, not during write");
 reset_case();frames(3,70,0,1000);en=0;frames(4,70,0,1000);en=1;
 frames(4,112,0,1000);check(events==0,"AE disable/re-enable clears stale statistics");
 reset_case();frames(3,70,0,1000);ready=0;frames(4,70,0,1000);ready=1;
 frames(4,112,0,1000);check(events==0,"camera not ready clears stale statistics");

 reset_case();exp=62;gain=16;frames(4,70,0,1000);
 check(events==1&&exp==63,"minimum exposure still makes forward progress");
 reset_case();exp=63;gain=16;frames(4,200,0,1000);
 check(events==1&&exp==62,"exposure lower clamp");
 reset_case();exp=1799;frames(4,70,0,1000);
 check(events==1&&exp==1800,"exposure upper clamp");
 reset_case();exp=1800;gain=142;frames(4,70,0,1000);
 check(events==1&&gain==143,"gain upper clamp");
 reset_case();gain=17;frames(4,200,0,1000);
 check(events==1&&gain==16,"gain lower clamp");
 reset_case();exp=62;gain=16;frames(8,200,0,1000);
 check(events==0,"no redundant request at lower bounds");
 reset_case();exp=1800;gain=143;frames(8,70,0,1000);
 check(events==0,"no redundant request at upper bounds");

 reset_case();en=0;plant_en=1;new_events=0;old_events=0;
 new_exp=1800;old_exp=1800;new_gain=16;old_gain=16;
 for(k=0;k<120;k=k+1)begin
  @(negedge clk);plant_done=1;@(negedge clk);plant_done=0;repeat(10)@(negedge clk);
 end
 check(old_events>=20,"frozen old AE reproduces steady-light gain oscillation");
 check(new_events==1&&new_gain==18&&new_mean==106,"new AE converges and holds in steady light");
 $display("PLANT_RESULT old_changes=%0d new_changes=%0d new_gain=%0d mean=%0d",old_events,new_events,new_gain,new_mean);
 plant_en=0;reset_case();en=0;plant_en=1;new_events=0;old_events=0;
 plant_level=360;new_exp=500;old_exp=500;new_gain=16;old_gain=16;
 for(k=0;k<120;k=k+1)begin
  @(negedge clk);plant_done=1;@(negedge clk);plant_done=0;repeat(10)@(negedge clk);
 end
 check(new_events==2&&new_exp==531&&new_mean==106,"small exposure steps converge without reversal");
 check(old_events==1&&old_exp==562&&old_mean==112,"exposure plant reference responds to old larger step");
 $display("EXPOSURE_PLANT old_exp=%0d new_exp=%0d old_changes=%0d new_changes=%0d",old_exp,new_exp,old_events,new_events);
 if(errors==0)$display("TEST_RESULT PASS ae_four_frame_filter_small_steps checks=%0d",checks);
 else $display("TEST_RESULT FAIL ae_four_frame_filter_small_steps errors=%0d checks=%0d",errors,checks);
 $finish;
end
endmodule
