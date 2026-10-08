`timescale 1ns/1ps
module tb_v27_camera;
 reg clk=0,rst=0,req=0;reg [15:0] exp=500,gain=108;reg nack_all=0;integer requests=0,errors=0,n;
 always #5 clk=~clk;
 wire scl,base_done,ae_done,err,fatal;wire [127:0] diag;tri1 sda;
 uicfgcs500 #(.CLK_DIV(7),.STARTUP_CYCLES(20),.SOFT_RESET_CYCLES(50),.RETRY_CYCLES(20),.TIMEOUT_CYCLES(2000)) dut(
 .I_clk(clk),.I_rst_n(rst),.I_ae_req(req),.I_ae(exp),.I_ag(gain),.O_cam_scl(scl),.IO_cam_sda(sda),
 .O_cfg_done(base_done),.O_ae_cfg_done(ae_done),.O_iic_error(err),.O_cfg_error(fatal),.O_diagnostics(diag));
 // Respond only in ACK slots; deliberately NACK one startup transfer, then all
 // bytes in one runtime request. Controller must retry the same register.
 assign sda=dut.uii2c_inst.IIC_S==3&&!nack_all&&requests!=2?1'b0:1'bz;
 always @(posedge dut.iic_req)begin
  requests=requests+1;
  if(!dut.startup_done)errors=errors+1;
 end
 task command;input [15:0] value;
 begin @(negedge clk);exp=value;req=1;@(negedge clk);req=0;wait(!ae_done);wait(ae_done);repeat(4)@(negedge clk);end
 endtask
 initial begin
  #31;rst=1;wait(ae_done);repeat(4)@(negedge clk);
  if(!base_done||fatal||err||diag[127:112]!=1||diag[111:96]!=1||diag[63:48]!=16'h0100||diag[24])errors=errors+1;
  nack_all=1;command(900);
  if(!err||fatal||diag[95:80]!=3||diag[63:48]!=16'h3e00||diag[39:32]!=1||diag[47:40]!=4)errors=errors+1;
  nack_all=0;command(950);if(err||fatal||dut.held_ae!=950)errors=errors+1;
  fork
   begin command(1000);end
   begin for(n=0;n<3;n=n+1)begin
    wait(dut.TS_S==4);force dut.iic_busy=1'b1;
    wait(dut.TS_S==6||dut.TS_S==0);release dut.iic_busy;@(negedge clk);
   end end
  join
  if(!err||diag[79:64]!=3||diag[39:32]!=2)errors=errors+1;
  rst=0;#20;rst=1;nack_all=1;wait(fatal);
  if(base_done||ae_done||diag[127:112]!=3||!diag[24])errors=errors+1;
  if(errors==0)$display("TEST_RESULT PASS v27_camera_retry_nack_timeout_and_fatal");
  else $display("TEST_RESULT FAIL camera errors%0d diag%h",errors,diag);
  $finish;
 end
 initial begin #3000000;$display("TEST_RESULT FAIL camera timeout diag%h state%0d",diag,dut.TS_S);$finish;end
endmodule
