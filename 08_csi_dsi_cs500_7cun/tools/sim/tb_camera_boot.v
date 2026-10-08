`timescale 1ns/1ps
// Actual control RTL and I2C engine; accelerated divider, sensor ACK responder.
module tb_camera_boot;
reg clk100=0,clk24=0,rst_n=0;
always #5 clk100=~clk100;
always #20.833333 clk24=~clk24;
reg [15:0] command_ae=16'd1700;
reg command_wr=0;
wire cfg_done,ae_done,ae_req,scl;
wire [15:0] exposure,gain;
tri1 sda;
integer transactions=0,errors=0,before_transactions;
assign sda=init_camera.uii2c_inst.IIC_S==3?1'b0:1'bz;
uicfgcs500 #(.CLK_DIV(3),.STARTUP_CYCLES(128),.SOFT_RESET_CYCLES(128),.RETRY_CYCLES(32),.TIMEOUT_CYCLES(2000)) init_camera(.I_clk(clk24),.I_rst_n(rst_n),.I_ae_req(ae_req),.I_ae(exposure),.I_ag(gain),.O_cam_scl(scl),.IO_cam_sda(sda),.O_cfg_done(cfg_done),.O_ae_cfg_done(ae_done));
cvp_proc proc_camera(.i_clk(clk100),.i_rst_n(rst_n),.i_mode(3'd0),.i_cam_cfg_done(cfg_done),.i_cmd_ae(command_ae),.i_cmd_ae_wr(command_wr),.i_grp_valid(1'b0),.i_grp_data(40'd0),.i_grp_frame_start(1'b0),.i_grp_line_last(1'b0),.o_ae_req(ae_req),.o_ae(exposure),.o_ag(gain),.o_pix_valid(),.o_pix_rgb(),.o_pix_frame_start(),.o_pix_line_last());
always @(posedge init_camera.iic_req) transactions=transactions+1;
always @(posedge clk100)
 if(rst_n && cfg_done===1'b0 && ae_req===1'b1) begin
  $display("FAIL: exposure request interrupts base setup");errors=errors+1;
 end
// Defend the consumer against an early request from an older producer.
wire protected_cfg,protected_ae,protected_scl;
tri1 protected_sda;
assign protected_sda=protected_camera.uii2c_inst.IIC_S==3?1'b0:1'bz;
uicfgcs500 #(.CLK_DIV(3),.STARTUP_CYCLES(128),.SOFT_RESET_CYCLES(128),.RETRY_CYCLES(32),.TIMEOUT_CYCLES(2000)) protected_camera(.I_clk(clk24),.I_rst_n(rst_n),.I_ae_req(!protected_cfg),.I_ae(16'd1700),.I_ag(16'd108),.O_cam_scl(protected_scl),.IO_cam_sda(protected_sda),.O_cfg_done(protected_cfg),.O_ae_cfg_done(protected_ae));
task check_boot;
begin
 if(cfg_done!==1'b1 || ae_done!==1'b1 || transactions==0) begin
  $display("FAIL: boot cfg=%b ae=%b writes=%0d",cfg_done,ae_done,transactions);errors=errors+1;
 end
 if(protected_cfg!==1'b1 || protected_ae!==1'b1) begin
  $display("FAIL: early request blocked protected consumer");errors=errors+1;
 end
end
endtask
task check_exposure(input [15:0] requested,input [15:0] expected);
begin
 before_transactions=transactions;
 @(negedge clk100);command_ae=requested;command_wr=1;
 @(negedge clk100);command_wr=0;
 #100000;
 if(exposure!==expected || ae_done!==1'b1 || ae_req!==1'b0 || transactions-before_transactions!=5) begin
  $display("FAIL: exposure request=%0d result=%0d expected=%0d writes=%0d",requested,exposure,expected,transactions-before_transactions);errors=errors+1;
 end
end
endtask
initial begin
 #200;rst_n=1;
 // An early network command must not precede camera initialization.
 @(negedge clk100);command_ae=16'd999;command_wr=1;
 @(negedge clk100);command_wr=0;
 #1000000;check_boot;
 if(exposure!==16'd1700) begin $display("FAIL: early command changed default exposure");errors=errors+1;end
 check_exposure(16'd1400,16'd1400);
 check_exposure(16'd0,16'd62);
 check_exposure(16'd65535,16'd1800);
 rst_n=0;#200;rst_n=1;#1000000;check_boot;
 if(exposure!==16'd1700) begin $display("FAIL: reset default exposure");errors=errors+1;end
 if(errors==0)$display("TEST_RESULT PASS camera_boot_and_exposure");
 else $display("TEST_RESULT FAIL camera_boot errors=%0d",errors);
 $finish;
end
endmodule
