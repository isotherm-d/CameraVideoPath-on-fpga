`timescale 1ns/1ps
// Full RGMII byte stimulus, using the vendor PH1P_LOGIC_HD_IDDR model.
module tb_udp_command_rx;
reg rxclk=0,clk100=0,rst_n=0;
always #4 rxclk=~rxclk;
always #5 clk100=~clk100;
reg [3:0] rxd=0;
reg rxctl=0;
wire [1:0] mode;
wire [15:0] exposure;
wire [8:0] gain_r,gain_g,gain_b;
wire swap,awb_en,exp_wr;
wire [6:0] kelvin;
wire [7:0] events;
integer errors=0,exposure_events=0;
reg [7:0] frame[0:71];
integer i,length;
reg [7:0] saved_events;
cvp_cmd_rx dut(.I_rxclk(rxclk),.I_rst_n_rx(rst_n),.I_rxd(rxd),.I_rxctl(rxctl),.I_rst_n_gmii(rst_n),.I_clk_gmii(rxclk),.I_clk100(clk100),.I_rst_n_100(rst_n),.o_mode(mode),.o_net_ae(exposure),.o_gain_r(gain_r),.o_gain_g(gain_g),.o_gain_b(gain_b),.o_swap(swap),.o_awb_en(awb_en),.o_kelvin(kelvin),.o_exp_wr(exp_wr),.o_evt_cnt(events));
always @(posedge clk100) if(exp_wr) exposure_events=exposure_events+1;
task send_byte(input [7:0] value);
begin
 @(negedge rxclk);#1;rxd=value[3:0];rxctl=1;
 @(posedge rxclk);#1;rxd=value[7:4];
end
endtask
task idle;
begin
 @(negedge rxclk);#1;rxctl=0;rxd=0;
 repeat(24) @(negedge rxclk);
end
endtask
// invalid: 0=valid, 1=bad magic, 2=wrong port, 3=truncated value.
task send_cmd(input [7:0] command,input [23:0] value,input integer invalid);
begin
 for(i=0;i<72;i=i+1)frame[i]=0;
 for(i=0;i<7;i=i+1)frame[i]=8'h55;
 frame[7]=8'hd5;
 for(i=8;i<14;i=i+1)frame[i]=8'hff;
 frame[14]=8'h02;frame[19]=8'h01;
 frame[20]=8'h08;frame[21]=0;
 frame[22]=8'h45;frame[25]=8'd36;frame[30]=8'd64;
 frame[31]=8'h11; // Actual IP protocol offset, corrected from the legacy TB.
 frame[34]=192;frame[35]=168;frame[36]=1;frame[37]=100;
 frame[38]=192;frame[39]=168;frame[40]=1;frame[41]=255;
 frame[42]=8'h0f;frame[43]=8'ha0;
 frame[44]=8'h17;frame[45]=8'h71;frame[47]=8'd16;
 frame[50]=8'hc5;frame[51]=8'ha5;frame[52]=8'h50;frame[53]=8'h01;
 frame[54]=command;
 frame[55]=value[23:16];frame[56]=value[15:8];frame[57]=value[7:0];
 if(invalid==1)frame[50]=8'hde;
 if(invalid==2)frame[45]=8'h70;
 length=(invalid==3)?57:72;
 for(i=0;i<length;i=i+1)send_byte(frame[i]);
 idle;#200;
end
endtask
task check(input condition,input [8*64-1:0] message);
begin
 if(condition!==1'b1)begin $display("FAIL: %0s",message);errors=errors+1;end
end
endtask
initial begin
 #100;rst_n=1;idle;
 check(events===8'd0,"event counter reset");
 send_cmd(0,24'd2,0);check(mode===2'd2,"mode low byte");
 send_cmd(1,24'd1700,0);check(exposure===16'd1700,"exposure 1700 decoded exactly");
 check(exposure_events==1,"one exposure write pulse");
 send_cmd(1,24'h123456,0);check(exposure===16'h3456,"three value bytes consumed");
 check(exposure_events==2,"second exposure write pulse");
 send_cmd(2,24'd438,0);check(gain_r===9'd438,"red gain 438");
 send_cmd(3,24'd386,0);check(gain_g===9'd386,"green gain 386");
 send_cmd(4,24'd371,0);check(gain_b===9'd371,"blue gain 371");
 send_cmd(5,24'd1,0);check(swap===1'b1,"red/blue swap");
 send_cmd(6,24'd0,0);check(awb_en===1'b0,"manual white balance");
 send_cmd(7,24'd65,0);check(kelvin===7'd65,"color temperature 6500K");
 saved_events=events;
 send_cmd(1,24'd999,1);send_cmd(1,24'd999,2);send_cmd(1,24'd999,3);
 check(events===saved_events,"malformed commands rejected");
 check(exposure===16'h3456,"invalid packets preserve exposure");
 check(exposure_events==2,"invalid packets do not trigger exposure writes");
 send_cmd(1,24'd1800,0);check(exposure===16'd1800,"recovery after malformed packets");
 check(exposure_events==3,"one final exposure write");
 if(errors==0)$display("TEST_RESULT PASS udp_command_rx");
 else $display("TEST_RESULT FAIL udp_command_rx errors=%0d",errors);
 $finish;
end
endmodule
