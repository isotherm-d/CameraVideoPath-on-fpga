
`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description: sdram as ram top module
//////////////////////////////////////////////////////////////////////////////////

// `include "../source_code/include/global_def.v"
`include "./global_def.v"
module ddr1_as_ram  #( parameter self_refresh_open=1)
	( 
	    input   		Clk0,
		input			Clk90,
		input			Clk180,
        input   		Rst,
			  			  
		output			Sdr_init_done,
		output			Sdr_init_ref_vld,
		output	    	Sdr_busy,
		
		input			App_ref_req,		
		
        input						App_wr_en, 
        input  [`ADDR_WIDTH-1:0]	App_wr_addr,  	////row[10:0],bank[1:0],col[7:0]
		input	[`DM_WIDTH-1:0]		App_wr_dm,
		input	[`DATA_WIDTH*2-1:0]	App_wr_din,
		
		input						App_rd_en,
		input	[`ADDR_WIDTH-1:0]	App_rd_addr,
		output						Sdr_rd_en,	//synthesis keep
		output	[`DATA_WIDTH*2-1:0]	Sdr_rd_dout,
		

		output							CLK,
		output							CLKN,
		output							CKE,
		output							CS_N,
		output  						RAS_N,
		output							CAS_N,
		output							WE_N,
		output		[`BA_WIDTH-1:0]		BA,
		output		[`ROW_WIDTH-1:0]	ADDR,
		output		[`DM_WIDTH-1:0]		DM,
		inout		[`DATA_WIDTH-1:0]	DQ,
		inout		[`DATA_WIDTH/8-1:0] DQS
		
	);
`pragma protect begin

wire			Sdr_init_done_wire;

wire			Sdr_rw_vld;

wire			Sdr_ref_req,Sdr_ref_ack;

wire			Sdr_init_ref_vld_wire;
wire			Sdr_init_ref_ras;
wire			Sdr_init_ref_cas;
wire			Sdr_init_ref_we;
wire	[`BA_WIDTH-1:0]	Sdr_init_ref_ba;
wire	[`ROW_WIDTH:0]	Sdr_init_ref_addr;

ddr1_init_ref #( .self_refresh_open(self_refresh_open))
	u1_init_ref( 
	   .Clk0(Clk0),
       .Rst(Rst),
			  			  
		////change sdr work mode
		.Sdr_init_req(1'b0),
        .Sdr_init_mode(), ////[2:0]: Burst Lenth, [3]:M9 ,1=sigle write
		.Sdr_init_done(Sdr_init_done_wire),
		
		////check wrtie and read busy 
		.App_ref_req(App_ref_req),
		.Sdr_ref_req(Sdr_ref_req),	//it must have 4096 refersh command in 64ms,send 1 time in 15.625ms
		.Sdr_ref_ack(Sdr_ref_ack),	//tXSR time is required delay after CKE going high to complete SelfRefresh exit(about 56.5ns)
		.Sdr_rw_vld(Sdr_rw_vld),

		.Sdr_init_ref_vld(Sdr_init_ref_vld_wire),
        .Sdr_init_ref_ras(Sdr_init_ref_ras),
		.Sdr_init_ref_cas(Sdr_init_ref_cas),
		.Sdr_init_ref_we(Sdr_init_ref_we),
		.Sdr_init_ref_ba(Sdr_init_ref_ba),
		.Sdr_init_ref_addr(Sdr_init_ref_addr)
	);
	
ddr1_wrrd u2_wrrd( 
		.Clk0(Clk0),
		.Clk90(Clk90),
		.Clk180(Clk180),
		.Rst(Rst),
			  			  
		.Sdr_init_done(Sdr_init_done_wire),

		.Sdr_rw_vld(Sdr_rw_vld),
		.Sdr_busy(Sdr_busy),
		
        .App_wr_en(App_wr_en), 
        .App_wr_addr(App_wr_addr),  	////row[10:0],bank[1:0],col[7:0]
		.App_wr_dm(App_wr_dm),
		.App_wr_din(App_wr_din),

		.App_rd_en(App_rd_en),
		.App_rd_addr(App_rd_addr),
		.Sdr_rd_en	(Sdr_rd_en),
		.Sdr_rd_dout(Sdr_rd_dout),

		.Sdr_ref_req(Sdr_ref_req),
		.Sdr_ref_ack(Sdr_ref_ack),	
		.Sdr_init_ref_vld(Sdr_init_ref_vld_wire),
        .Sdr_init_ref_ras(Sdr_init_ref_ras),
		.Sdr_init_ref_cas(Sdr_init_ref_cas),
		.Sdr_init_ref_we(Sdr_init_ref_we),
		.Sdr_init_ref_ba(Sdr_init_ref_ba),
		.Sdr_init_ref_addr(Sdr_init_ref_addr),
		
		.CLK(CLK),
		.CLKN(CLKN),
		.CKE(CKE),
		.CS_N(CS_N),
		.RAS_N(RAS_N),
		.CAS_N(CAS_N),
		.WE_N(WE_N),
		.BA(BA),
		.ADDR(ADDR),
		.DM(DM),
		.DQ(DQ),
		.DQS(DQS)
	);		
assign Sdr_init_done = Sdr_init_done_wire;
assign Sdr_init_ref_vld = Sdr_init_ref_vld_wire;

`pragma protect end

endmodule


