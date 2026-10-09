
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description: sdram init and refresh
//////////////////////////////////////////////////////////////////////////////////

`define signle_bit 0

// `include "../source_code/include/global_def.v"
`include "./global_def.v"
`pragma protect begin

module ddr1_init_ref #( parameter self_refresh_open=1)
	(
	    input   		Clk0,
        input   		Rst,
			  			  
		////change sdr work mode
		input			Sdr_init_req,
        input	[3:0]	Sdr_init_mode, ////[2:0]: Burst Lenth, [3]:M9 ,1=sigle write
		output 			Sdr_init_done,
		
		////check wrtie and read busy	
		input			App_ref_req,	
		output			Sdr_ref_req,	//it must have 4096 refersh command in 64ms,send 1 time in 15.625ms
		input			Sdr_ref_ack,
		input			Sdr_rw_vld,

		output	reg		Sdr_init_ref_vld,
        output			Sdr_init_ref_ras,
		output			Sdr_init_ref_cas,
		output			Sdr_init_ref_we,
		output	[`BA_WIDTH-1:0]	Sdr_init_ref_ba,
		output	[`ROW_WIDTH-1:0]	Sdr_init_ref_addr

	);



reg		[17:0]	pwr_200ms_cnt;
reg 			power_up_200ms_1d,power_up_200ms_2d,power_up_200ms_3d,power_up_200ms_4d,power_up_en;
reg		[13:0]	init_cnt;

reg 			sdr_init_en;
reg 			init_vld,init_done,init_done_1d;
reg		[19:0]	sdr_ref_ack_sft;
reg				ref_req,ref_vld;

reg	[3:0]	cmd_dly;
reg	[3:0]	cmd_tx_cnt;
reg	[2:0]	ddr_cmd;

reg 					ras,cas,we;
reg 	[`ROW_WIDTH-1:0]addr;
reg		[`BA_WIDTH-1:0]	ba;
reg						cke;

localparam INIT_IDLE    = 4'h0;
localparam PRECHARGE    = 4'h1;
localparam EMRS         = 4'h2;
localparam MRS_RSTDLL	= 4'h3;
localparam AR			= 4'h4;
localparam MRS_A8L_NORMAL= 4'h5;
localparam INIT_OVER	= 4'h6;
reg	[2:0]	INIT_STA=0;


//pipe
always @(posedge Clk0)
begin
	if(Rst)
		pwr_200ms_cnt <= 17'd0;
	else if(pwr_200ms_cnt[17])
		pwr_200ms_cnt <= pwr_200ms_cnt;
	else
		pwr_200ms_cnt <= pwr_200ms_cnt+1'b1;
	

end

always @(posedge Clk0)
begin
	power_up_200ms_1d <= pwr_200ms_cnt[17];
	power_up_200ms_2d <= power_up_200ms_1d;
	power_up_200ms_3d <= power_up_200ms_2d;
	power_up_200ms_4d <= power_up_200ms_3d;
	power_up_en <= power_up_200ms_1d & (!power_up_200ms_2d);
	
	sdr_init_en <= power_up_en | Sdr_init_req;	
	Sdr_init_ref_vld <= init_vld	| ref_vld;
end


////init cunt
always @(posedge Clk0)
begin  
	if (Rst)
        init_cnt <= 14'd0;   
	else
		if(init_cnt==14'd10000)
			init_cnt <= 14'd0;
		else
			init_cnt <= init_cnt+1'b1;
end

////ref ack shift
always @(posedge Clk0)
begin  
	if (Rst)
		sdr_ref_ack_sft <= 'd0;
	else
		begin
			sdr_ref_ack_sft[0]	<= Sdr_ref_ack;
			sdr_ref_ack_sft[19:1]	<= sdr_ref_ack_sft[18:0];
		end
end


////self refresh
always @(posedge Clk0)
begin  
	if (Rst)
		begin
			ref_req <= 1'd0;   
			ref_vld <= 1'b0;
		end
	else begin
		if(self_refresh_open)
			if(init_cnt==14'd9990 && (!Sdr_ref_ack))	////if previous ack allign current ref req
				ref_req <= 1'b1;
			else
				ref_req <= 1'b0;
		else
			ref_req <= 1'b0;

			
		if(Sdr_ref_ack && (~Sdr_rw_vld))
			ref_vld <= 1'b1;
		else if(sdr_ref_ack_sft[19])
			ref_vld <= 1'b0;
	
	end
end
assign Sdr_ref_req=ref_req | App_ref_req;

////cmd delay cnt
always @(posedge Clk0)
begin  
	if(Rst)
		cmd_dly <= 'd0;
	else if(power_up_200ms_4d)
		if(cmd_dly[3])
			cmd_dly <= 'd0;
		else
			cmd_dly <= cmd_dly+1'b1;
end


////
always @(posedge Clk0)
begin  
	if(Rst || sdr_init_en)
		begin
			INIT_STA <= 'd0;
			cmd_tx_cnt <= 'd0;
			init_vld <= 'd0;
			ddr_cmd <=3'b000;
			init_done <= 1'b0;
		end
	else if(power_up_200ms_4d)
		case(INIT_STA) 
			INIT_IDLE :		begin
								INIT_STA <= PRECHARGE;
								init_vld <= 1'b1;
								ddr_cmd <=3'b000;
								cmd_tx_cnt <= 'd0;
							end
			
			PRECHARGE:		begin
								
								if(cmd_dly[3])
									begin
										ddr_cmd <=3'b001;
										if(cmd_tx_cnt <= 'd2)
											begin
												INIT_STA <= EMRS;
												cmd_tx_cnt <= cmd_tx_cnt+1'b1;
											end
										else
											INIT_STA <= AR;
									end
								else
									begin
										INIT_STA <= PRECHARGE;
										ddr_cmd <=3'b000;
									end
							end

			EMRS	:		begin
								
								if(cmd_dly[3])
									begin
										ddr_cmd <=3'b010;
										INIT_STA <= MRS_RSTDLL;
										cmd_tx_cnt <= cmd_tx_cnt+1'b1;
									end
								else
									begin
										INIT_STA <= EMRS;
										ddr_cmd <= 3'b000;
									end
							end						
			MRS_RSTDLL	:	begin
								
								if(cmd_dly[3])
									begin
										ddr_cmd <=3'b011;
										INIT_STA <= PRECHARGE;
										cmd_tx_cnt <= cmd_tx_cnt+1'b1;
									end
								else begin
										INIT_STA <= MRS_RSTDLL;
										ddr_cmd <= 3'b000;
									end
							end
			AR:				begin
								
								if(cmd_dly[3])
									begin
										ddr_cmd=3'b100;
										if(cmd_tx_cnt <= 'd5)
											begin
												INIT_STA <= AR;
												cmd_tx_cnt <= cmd_tx_cnt+1'b1;
											end
										else
											INIT_STA <= MRS_A8L_NORMAL;
									end
								else begin
										INIT_STA <= AR;
										ddr_cmd <=4'b000;
									end
							end
			MRS_A8L_NORMAL:	begin
								
								if(cmd_dly[3])
									begin
										INIT_STA <= INIT_OVER;
										ddr_cmd <= 3'b101;
									end
								else begin
										INIT_STA <= MRS_A8L_NORMAL;
										ddr_cmd <=3'b000;
									end
							end
			INIT_OVER:		begin
								ddr_cmd <=3'b000;
								if(cmd_dly[3])
									begin
										init_done <= 1'b1;
										init_vld <= 1'b0;
									end
							end
			default : begin
							INIT_STA <= 'd0;
							cmd_tx_cnt <= 'd0;
							init_vld <= 'd0;
							ddr_cmd <= 'b000;
						end
		endcase
end

////command
always @(posedge Clk0)
begin  
	if(Rst)
		begin
			{ras,cas,we} <= `CMD_NOP;
			addr <= 'd0;
			ba <= 'd0;
		end
    else if (ddr_cmd==3'b001) //precharge command
		begin
			{ras,cas,we} <=`CMD_PRECHARGE;
			addr[10] <= 'd1;
			addr[8] <= 'd1;
			ba <= 'd0;
		end
    else if (ddr_cmd==3'b010) //EMRS
		begin
			{ras,cas,we} <= `CMD_EXT_MODE_REGISTER;
			addr <= 'd0;
			ba[0] <= 'd1;
		end
    else if (ddr_cmd==3'b011) //MRS,rst dll,a8=1
		begin
			{ras,cas,we} <= `CMD_LOAD_MODE_REGISTER;
			addr[8] <= 'd1;
			addr[6:4] <= `Latency_3;
			addr[3] <= `Burst_type;
			addr[2:0] <= `Burst_Length;
			ba[0] <= 'd0;
		end
    else if (ddr_cmd==3'b100) //AR
		begin
			{ras,cas,we} <= `CMD_AUTO_REFRESH;
			addr <= 'd0;
			ba[0] <= 'd0;
		end	
    else if (ddr_cmd==3'b101) ////MRS,rst dll,a8=1
		begin
			{ras,cas,we} <= `CMD_LOAD_MODE_REGISTER;
			addr[8] <= 'd0;
			addr[6:4] <= `Latency_3;
			addr[3] <= `Burst_type;
			addr[2:0] <= `Burst_Length;
			ba[0] <= 'd0;
		end
	else begin
			{ras,cas,we} <= `CMD_NOP;
		end
end	



assign	Sdr_init_ref_ras = ras;
assign	Sdr_init_ref_cas = cas;
assign	Sdr_init_ref_we = we;
assign	Sdr_init_ref_addr = addr;
assign  Sdr_init_ref_ba = ba;
assign SDR_CKE=1'b1;

////init done flag
always @(posedge Clk0)
begin  
	if (sdr_init_en || Rst)
	    init_done_1d <= 1'b0;
	else 
	    init_done_1d <= init_done;
end
assign Sdr_init_done = init_done_1d;


// synthesis translate_off
reg  [8*30:1] sta_cal4_ascii;
always @(INIT_STA)
begin
  case (INIT_STA)
    4'd0        : sta_cal4_ascii <=  "INIT_IDLE";
    4'd1        : sta_cal4_ascii <=  "PRECHARGE";
    4'd2        : sta_cal4_ascii <=  "EMRS";
    4'd3        : sta_cal4_ascii <=  "MRS_RSTDLL"; 
    4'd4        : sta_cal4_ascii <=  "AR";
    4'd5        : sta_cal4_ascii <=  "MRS_A8L_NORMA";
    4'd6        : sta_cal4_ascii <=  "INIT_OVER";
  endcase
end
// synthesis translate_on




endmodule

`pragma protect end	
