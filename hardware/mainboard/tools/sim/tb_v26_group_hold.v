`timescale 1ns/1ps
// Real I2C sequencer + sensor group-latch model, including a frame event
// between each register. Partial exposure bytes must never become active.
module tb_v26_group_hold;
 reg clk=0,rst=0,req=0;always #5 clk=~clk;tri1 sda;
 reg [15:0] exposure=511,gain=108;wire ae_done,base_done,err,fatal;wire [127:0] diag;
 uicfgcs500 #(.CLK_DIV(3),.STARTUP_CYCLES(20),.SOFT_RESET_CYCLES(20),.RETRY_CYCLES(20),.TIMEOUT_CYCLES(4000)) dut(
  .I_clk(clk),.I_rst_n(rst),.I_ae_req(req),.I_ae(exposure),.I_ag(gain),.O_cam_scl(),.IO_cam_sda(sda),
  .O_cfg_done(base_done),.O_ae_cfg_done(ae_done),.O_iic_error(err),.O_cfg_error(fatal),.O_diagnostics(diag));
 assign sda=dut.uii2c_inst.IIC_S==3?1'b0:1'bz;
 integer errors=0,writes=0,phase=0;reg holding=0,sealed=0,launch=0;
 reg [15:0] shadow_exp=0,active_exp=0;reg [15:0] shadow_gain=0,active_gain=0;
 reg [15:0] address;reg [7:0] value;
 always @(posedge dut.iic_req)if(dut.table_kind==2)begin
  address={dut.wr_data[15:8],dut.wr_data[23:16]};value=dut.wr_data[31:24];writes=writes+1;
  case(phase)
   0:if(address!=16'h3817||value!=8'h20)errors=errors+1;
   1:begin if(address!=16'h3800||value!=0)errors=errors+1;holding=1;sealed=0;end
   2:shadow_exp[15:12]=value[3:0];
   3:shadow_exp[11:4]=value;
   4:shadow_exp[3:0]=value[7:4];
   5:shadow_gain[15:8]=value;
   6:shadow_gain[7:0]=value;
   7:begin if(address!=16'h3800||value!=8'h10)errors=errors+1;holding=0;sealed=1;end
   8:begin if(address!=16'h3800||value!=8'h40||!sealed)errors=errors+1;launch=1;end
  endcase
  if(phase<8&&active_exp!=511)errors=errors+1;
  phase=phase+1;
 end
 initial begin
  #31;rst=1;wait(ae_done);repeat(4)@(negedge clk);
  active_exp=511;active_gain=16'h0f3c;shadow_exp=active_exp;shadow_gain=active_gain;
  @(negedge clk);exposure=512;req=1;@(negedge clk);req=0;wait(!ae_done);wait(ae_done);
  repeat(4)@(negedge clk);
  if(writes!=9||!launch||active_exp!=511||shadow_exp!=512||shadow_gain!=16'h0f3c||err||fatal)errors=errors+1;
  // Sensor applies the sealed group on its next frame latch, not at I2C ACK.
  if(launch)begin active_exp=shadow_exp;active_gain=shadow_gain;launch=0;end
  if(active_exp!=512)errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS SC500CS_group0_atomic_next_frame_exposure writes=%0d",writes);
  else $display("TEST_RESULT FAIL group hold errors=%0d writes=%0d active=%0d shadow=%0d gain=%h",errors,writes,active_exp,shadow_exp,shadow_gain);
  $finish;
 end
 initial begin #3000000;$display("TEST_RESULT FAIL group hold timeout");$finish;end
endmodule
