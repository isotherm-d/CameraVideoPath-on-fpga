

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description: sdram write and read operate
//////////////////////////////////////////////////////////////////////////////////


// `include "../source_code/include/global_def.v"
`include "./global_def.v"

`pragma protect begin

module ddr1_wrrd( 
	    input   		Clk0,
		input			Clk90,
		input			Clk180,
        input   		Rst,
			  			  
		input			Sdr_init_done,

		output			Sdr_rw_vld,
		output	reg		Sdr_busy,
		
        input											App_wr_en, 
        input  [`ROW_WIDTH+`BA_WIDTH+`COL_WIDTH-1:0]	App_wr_addr,  	////row[10:0],bank[1:0],col[7:0]
		input	[`DM_WIDTH-1:0]							App_wr_dm,
		input	[`DATA_WIDTH*2-1:0]						App_wr_din,	
		
		input											App_rd_en,
		input	[`ROW_WIDTH+`BA_WIDTH+`COL_WIDTH-1:0]	App_rd_addr,
		output							Sdr_rd_en,	
		output reg	[`DATA_WIDTH*2-1:0] Sdr_rd_dout,
		
		input			Sdr_ref_req,
		output	reg		Sdr_ref_ack,		
		input			Sdr_init_ref_vld,
        input			Sdr_init_ref_ras,
		input			Sdr_init_ref_cas,
		input			Sdr_init_ref_we,
		input	[1:0]	Sdr_init_ref_ba,
		input	[11:0]	Sdr_init_ref_addr,
		
		output				CLK,
		output				CLKN,
		output				CS_N,
		output				CKE,
		output	reg			RAS_N,
		output	reg			CAS_N,
		output	reg			WE_N,
		output	reg	[`BA_WIDTH-1:0]		BA,
		output	reg	[`ROW_WIDTH-1:0]	ADDR,
		output	reg	[`DM_WIDTH-1:0]		DM,
		inout		[`DATA_WIDTH-1:0]	DQ,
		inout		[`DATA_WIDTH/8-1:0] DQS
		
	);

reg	[`ROW_WIDTH+`BA_WIDTH+`COL_WIDTH-1:0]	app_wr_addr_0d,app_wr_addr_1d,app_wr_addr_2d,app_wr_addr_3d,app_wr_addr_4d,app_wr_addr_5d;
reg	[`DATA_WIDTH*2-1:0]	app_wr_din_0d,app_wr_din_1d,app_wr_din_2d,app_wr_din_3d,app_wr_din_4d,app_wr_din_5d,app_wr_din_6d,app_wr_din_7d,app_wr_din_8d;
reg	[`DM_WIDTH-1:0]		app_wr_dm_0d,app_wr_dm_1d,app_wr_dm_2d,app_wr_dm_3d,app_wr_dm_4d,app_wr_dm_5d,app_wr_dm_6d;
reg	[`ROW_WIDTH+`BA_WIDTH+`COL_WIDTH-1:0]	app_rd_addr_0d,app_rd_addr_1d,app_rd_addr_2d,app_rd_addr_3d,app_rd_addr_4d,app_rd_addr_5d;
reg	[9:0]		app_wr_en_sft;
reg [15:0]      app_rd_en_sft;
reg				active_en;
reg	[`ROW_WIDTH-1:0]	active_row;
reg	[`BA_WIDTH-1:0]		active_ba;
reg				col_en;
reg	[`COL_WIDTH-1:0]		active_col;
reg				rw_vld;

reg		[`ROW_WIDTH-1:0]op_addr;
reg		[`BA_WIDTH-1:0]	bank;
reg						ras,cas,we;
reg						dq_wvld,dq_t;

////pipeline
always @(posedge Clk0)
begin	
	app_wr_addr_0d <= App_wr_addr;
	app_wr_addr_1d <= app_wr_addr_0d;
	app_wr_addr_2d <= app_wr_addr_1d;
	app_wr_addr_3d <= app_wr_addr_2d;
	app_wr_addr_4d <= app_wr_addr_3d;
	app_wr_addr_5d <= app_wr_addr_4d;
	
	app_wr_din_0d <= App_wr_din;
	app_wr_din_1d <= app_wr_din_0d;
	app_wr_din_2d <= app_wr_din_1d;
	app_wr_din_3d <= app_wr_din_2d;
	app_wr_din_4d <= app_wr_din_3d;
	app_wr_din_5d <= app_wr_din_4d;
	app_wr_din_6d <= app_wr_din_5d;
	app_wr_din_7d <= app_wr_din_6d;
	app_wr_din_8d <= app_wr_din_7d;
	
	app_wr_dm_0d <= App_wr_dm;
	app_wr_dm_1d <= app_wr_dm_0d;
	app_wr_dm_2d <= app_wr_dm_1d;
	app_wr_dm_3d <= app_wr_dm_2d;
	app_wr_dm_4d <= app_wr_dm_3d;
	app_wr_dm_5d <= app_wr_dm_4d;
	app_wr_dm_6d <= app_wr_dm_5d;

	app_rd_addr_0d <= App_rd_addr;
	app_rd_addr_1d <= app_rd_addr_0d;
	app_rd_addr_2d <= app_rd_addr_1d;
	app_rd_addr_3d <= app_rd_addr_2d;
	app_rd_addr_4d <= app_rd_addr_3d;
	app_rd_addr_5d <= app_rd_addr_4d;
end

//shift
always @(posedge Clk0)
begin
	if(Rst)
		begin
			app_wr_en_sft <= 'd0;
			app_rd_en_sft <= 'd0;
		end
	else begin
			app_wr_en_sft[0] <= App_wr_en;
			app_wr_en_sft[9:1] <= app_wr_en_sft[8:0];
			
			app_rd_en_sft[0] <= App_rd_en;
			app_rd_en_sft[15:1] <= app_rd_en_sft[14:0];
		end
end



////active
always @(posedge Clk0)
begin
	if(Rst)
		active_en <= 'd0;
	else
		active_en <= (app_wr_en_sft[0] & (~app_wr_en_sft[1])) | (app_rd_en_sft[0] & (~app_rd_en_sft[1]));
end

////row addr
always @(posedge Clk0)
begin
	if(Rst)
		active_row <= 'd0;
	else if(app_wr_en_sft[0] & (~app_wr_en_sft[1]))
		active_row <= app_wr_addr_0d[(`COL_WIDTH-1+`BA_WIDTH+`ROW_WIDTH):(`COL_WIDTH+`BA_WIDTH)];
	else if(app_rd_en_sft[0] & (~app_rd_en_sft[1]))
		active_row <= app_rd_addr_0d[(`COL_WIDTH-1+`BA_WIDTH+`ROW_WIDTH):(`COL_WIDTH+`BA_WIDTH)];
end

////bank addr
always @(posedge Clk0)
begin
	if(Rst)
		active_ba<= 'd0;
	else if(app_wr_en_sft[0] & (~app_wr_en_sft[1]))
		active_ba <= app_wr_addr_0d[(`COL_WIDTH-1+`BA_WIDTH):(`COL_WIDTH)];
	else if(app_rd_en_sft[0] & (~app_rd_en_sft[1]))
		active_ba <= app_rd_addr_0d[(`COL_WIDTH-1+`BA_WIDTH):(`COL_WIDTH)];
end

////read col en
always @(posedge Clk0)
begin
	if(Rst)
		col_en <= 'd0;
	else
		col_en <= app_wr_en_sft[4] | app_rd_en_sft[4];
end

////wrrd col addr
always @(posedge Clk0)
begin
	if(Rst)
		active_col<= 'd0;
	else if(app_wr_en_sft[4])
		active_col <= app_wr_addr_4d[`COL_WIDTH-1:0];
	else if(app_rd_en_sft[4])
		active_col <= app_rd_addr_4d[`COL_WIDTH-1:0];
end

////sdr write read valid
always @(posedge Clk0)
begin
	if(Rst)
		rw_vld <= 'b0;
	else if((app_wr_en_sft[7] & (~app_wr_en_sft[6]))  | (app_rd_en_sft[10] & (~app_rd_en_sft[9])))
		rw_vld <= 1'b0;
	else if(app_wr_en_sft[0] | app_rd_en_sft[0])
		rw_vld <= 1'b1;
end
assign Sdr_rw_vld=rw_vld | App_wr_en | App_rd_en;


/////cmd
always @(posedge Clk0)
begin	 
	if (active_en)     ////active row and bank,only for write or read
			begin
				op_addr <= active_row;
				bank <= active_ba;
				ras <= 1'b0;
				cas <= 1'b1;
				we  <= 1'b1;
			end
			
			
	else if(col_en) ////wr rd col,,only for write or read
			begin
				op_addr[8:0] <= active_col;
				if((app_wr_en_sft[5] & (~app_wr_en_sft[4])) || (app_rd_en_sft[5] & (~app_rd_en_sft[4])))
					begin
						op_addr[10] <= 1'b1;	//with prechage
						//op_addr[8] <= 1'b1;	//with prechage
					end
				else
					begin
						op_addr[10] <= 1'b0;
						//op_addr[8] <= 1'b0;
					end
				bank <= bank;
			
				case({app_wr_en_sft[5],app_rd_en_sft[5]})
					2'b10 :
							begin
								ras <= 1'b1;
								cas <= 1'b0;
								we  <= 1'b0;
							end
					2'b01:
							begin
								ras <= 1'b1;
								cas <= 1'b0;
								we  <= 1'b1;
							end
					default:
							begin
								ras <= 1'b1;
								cas <= 1'b1;
								we  <= 1'b1;
							end
				endcase
			end
	 else begin	
			ras <= 1'b1;
			cas <= 1'b1;
			we  <= 1'b1;
		end
end

//sel
always @(posedge Clk0)
begin		
	case(rw_vld)
		1'b0 :
			begin
				RAS_N <=	Sdr_init_ref_ras;
				CAS_N <=	Sdr_init_ref_cas;
				WE_N  <=	Sdr_init_ref_we;
				BA	<=  Sdr_init_ref_ba;
				ADDR <= Sdr_init_ref_addr;
			end
		default:
			begin
				RAS_N <=	ras;
				CAS_N <=	cas;
				WE_N  <=	we;
				BA	<=  bank;
				ADDR <= op_addr;
			end
	endcase
end
assign CS_N=1'b0;
assign CKE=1'b1;

//dm
always @(posedge Clk0)
begin
	if(Rst)
		DM  <= 4'b1111;
	else
		DM <= app_wr_dm_6d;
end

EG_LOGIC_ODDR ODDR2_p (
			.q(CLK), 
			.clk(Clk0), 
			.d0(1'b0), 
			.d1(1'b1), 
			.rst(1'b0)
			);
EG_LOGIC_ODDR ODDR2_n (
			.q(CLKN), 
			.clk(Clk0), 
			.d0(1'b1), 
			.d1(1'b0), 
			.rst(1'b0)
			);

//////////////////////////DQS for write////////////////////////////////////////////
reg			dqs_oddr_on,dqs_oddr_on_1d,dqs_oddr_on_2d,dqs_oddr_on_1d_f;
wire	[`DATA_WIDTH/8-1:0]	dqsout;

always @(posedge Clk180) 
begin
	dqs_oddr_on <= app_wr_en_sft[7];
	dqs_oddr_on_1d <= dqs_oddr_on;
end

always @(negedge Clk180) 
begin
	dqs_oddr_on_1d_f <= dqs_oddr_on_1d;
end
wire dqs_t=dqs_oddr_on | dqs_oddr_on_1d;

generate
      genvar k;
      for (k=0; k<=`DATA_WIDTH/8-1; k=k+1)
		 begin: dqsout_oddr
          
				 EG_LOGIC_ODDR ODDR_dqsout_inst (
   
                        .q      (   dqsout[k]   ),                                      
                        .clk    (   Clk180   ),  
						`ifdef SIMULATION
							.d0     (   dqs_oddr_on), 
						`else
							.d0     (   dqs_oddr_on ),
						`endif
                        .d1     (   1'b0 ),                                      
                        .rst    (   1'b0 )
					);
		 end 
endgenerate
	     

generate
   genvar y;
   for (y=0; y<=`DATA_WIDTH/8-1; y=y+1)
		 begin: ddr_dqs_i_gen
			assign DQS[y]    = dqs_t ? dqsout[y]: 1'bz ;
		 end 
endgenerate

//assign CKE=dqs_t;
//
/////////////////////////////////////////////////////////////////


//////////////////////////  DQ   ///////////////////////////////
reg [`DATA_WIDTH-1:0]	dqout_p;
reg [`DATA_WIDTH-1:0]	dqout_n;
always @(posedge Clk90)
begin
	dqout_p <=app_wr_din_7d;
	dqout_n <=app_wr_din_7d[(`DATA_WIDTH*2-1) :`DATA_WIDTH];//32'hAAAAAAAA;
end

wire [`DATA_WIDTH-1:0]	dqout;
generate
      genvar i;
      for (i=0; i<=15; i=i+1)
       begin: dqout_oddr
         EG_LOGIC_ODDR ODDR_dqout_inst (
                        .q      (   dqout[i]         ),                                      
                        .clk    (   Clk90          ),                                    
                        .d0     (   dqout_p[i]    ),                                       
                        .d1     (   dqout_n[i] ),                                      
                        .rst    (   1'b0             ));
       end 
 endgenerate

//t
always @(posedge Clk90)
begin	
	if (Rst)
		begin
			dq_wvld <= 1'b0;
			dq_t <= 1'b0;
		end
	else begin
		`ifdef SIMULATION
			dq_wvld <= app_wr_en_sft[7];
		`else
			dq_wvld <= app_wr_en_sft[7];
		`endif
			dq_t <= dq_wvld;
		end
end

////output
wire	[`DATA_WIDTH-1:0]	ddr_dq_o;
generate
   genvar x;
   for (x=0; x<=`DATA_WIDTH-1; x=x+1)
    begin: dq_o_gen
      assign DQ[x]  = (dq_t || dq_wvld) ?  dqout[x]: 'bz ;
    end 
endgenerate

////////////////////////////////////////////////////////////////



/////////////////////DQ INPUT PROCESS /////////////////////////


wire			dq_iddr_clk = DQS[0];  //Clk0
wire	[`DATA_WIDTH-1:0]	dq_idelay=DQ;
reg		[`DATA_WIDTH-1:0]	stg1_out_rise_sg3,stg1_out_fall_sg3;
reg		[`DATA_WIDTH-1:0]	stg2a_out_rise,stg2a_out_fall;
wire	[`DATA_WIDTH-1:0]	stg3a_out_rise,stg3a_out_fall;
reg		[`DATA_WIDTH-1:0]	stg2b_out_rise,stg2b_out_fall,stg3b_out_rise,stg3b_out_fall;
wire			rd_data_sel=1'b1;

generate
   genvar m;
   for (m=0; m<=`DATA_WIDTH-1; m=m+1)
    begin: ddr_dq_i_gen
/*
		EG_LOGIC_IDDR #(.PIPEMODE("PIPED"))//PIPED
			u_iddr_dq_i
			(	.d(dq_idelay[m]), 
				.clk(dq_iddr_clk), 
				.q1(stg1_out_fall_sg3[m]), 
				.q0(stg1_out_rise_sg3[m]), 
				.rst(1'b0)
			);				
	*/
		always @(posedge dq_iddr_clk)
			stg1_out_rise_sg3[m]   <= dq_idelay[m];
		always @(negedge dq_iddr_clk)
			stg1_out_fall_sg3[m]   <= dq_idelay[m];


    end 
endgenerate


`ifdef USE_REG

//*********************************************************
	//// Slice #1 (posedge CLK): Used for:
	////  1. IDDR transfer to CLK0 rising edge domain ("stg2a")
	////  2. stg2 falling edge -> stg3 rising edge transfer
		//*********************************************************
////a
//// Stage 2 capture,from dq_iddr_clk domain to clk0 domain
always @(posedge Clk0)
	begin
		stg2a_out_rise <= stg1_out_rise_sg3;
		stg2a_out_fall <= stg1_out_fall_sg3;
	end


////b			
//// Stage 3 falling -> rising edge translation
always @(posedge Clk0)
	begin
		stg3b_out_rise <= stg2b_out_rise;
		stg3b_out_fall <= stg2b_out_fall;
	end	

////falling edge 		
//*********************************************************
// Slice #2 (posedge CLK): Used for:
////  1. IDDR transfer to CLK0 falling edge domain ("stg2b")
//*********************************************************
always @(negedge Clk0)
	begin
		stg2b_out_rise <= stg1_out_rise_sg3;
		stg2b_out_fall <= stg1_out_fall_sg3;
	end	

//*******************************************************************
assign stg3a_out_rise = stg2a_out_rise;
assign stg3a_out_fall = stg2a_out_fall;
////3a: ~dqs->clk0_r
////3b: ~dqs->clk0_f->clk0_r
wire [`DATA_WIDTH-1:0]	rd_data_rise = (rd_data_sel) ? stg3a_out_rise : stg3b_out_rise;
wire [`DATA_WIDTH-1:0]	rd_data_fall = (rd_data_sel) ? stg3a_out_fall : stg3b_out_fall;

reg	[`DATA_WIDTH-1:0]	rd_data_rise_tmp,rd_data_fall_tmp,rd_data_rise_tmp_1d;
always @(posedge Clk0)
begin
	rd_data_rise_tmp <= rd_data_rise;
	rd_data_rise_tmp_1d <= rd_data_rise_tmp;

	rd_data_fall_tmp <= rd_data_fall;

`ifdef SIMULATION
	Sdr_rd_dout <= {rd_data_fall_tmp,rd_data_rise_tmp_1d};
`else
	Sdr_rd_dout <= {rd_data_fall_tmp,rd_data_rise_tmp_1d};
`endif
end

`ifdef SIMULATION
	wire	ctrl_rden_sel=1'b1;
`else
	wire	ctrl_rden_sel=1'b0;
`endif
reg		ctrl_rden;
always @(posedge Clk0)
begin
    ctrl_rden  <= app_rd_en_sft[14];
end
// determine correct read data valid signal timing
assign Sdr_rd_en = ctrl_rden_sel ? app_rd_en_sft[14] : ctrl_rden;
//////////////////////////////////////////////////////////////////


`elsif USE_DRAM
////1.last clk do not write to dram,need delay dq_iddr_clk;
////2.dram use rising_edge clk default, need add falling edge clk to wirte data
reg			dram_rst;
reg			dram_we;
reg	[3:0]	waddr_r,waddr_f;
reg	[3:0]	raddr;
wire	[`DATA_WIDTH-1:0]	dout_r,dout_f;
reg	[`DATA_WIDTH-1:0]	dout_f_1d;
generate
   genvar ii;
   for (ii=0; ii<=`DATA_WIDTH-1; ii=ii+1)
    begin: ddr_dq_rx_dram

dram_16x1 dram_16xn_r (
		.di(stg1_out_rise_sg3[ii]), 
		.waddr(waddr_r), 
		.we(dram_we), 
		.wclk(!dq_iddr_clk), 
		.do(dout_r[ii]), 
		.raddr(raddr)
	);

dram_16x1 dram_16xn_f (
		.di(stg1_out_fall_sg3[ii]), 
		.waddr(waddr_f), 
		.we(dram_we), 
		.wclk(dq_iddr_clk), 
		.do(dout_f[ii]), 
		.raddr(raddr)
	);
    end 
endgenerate

always @(posedge Clk0)
	dram_rst <=  app_rd_en_sft[0] & (~app_rd_en_sft[1]);

always @(posedge Clk0)
	dram_we <= app_rd_en_sft[9] | app_rd_en_sft[11];

always @(posedge dq_iddr_clk or posedge dram_rst)
	if(dram_rst)
		waddr_r <= 'b1111;
	else if(dram_we)
		waddr_r <= waddr_r + 1'b1;

always @(negedge dq_iddr_clk or posedge dram_rst)
	if(dram_rst)
		waddr_f <= 'b1110;
	else if(dram_we)
		waddr_f <= waddr_f + 1'b1;
		

always @(posedge Clk0 or posedge dram_rst)
	if(dram_rst)
		raddr <= 'b1111;
	else if(app_rd_en_sft[14])
		raddr <= raddr + 1'b1;


always @(posedge Clk0)
begin
    dout_f_1d <= dout_f;
	Sdr_rd_dout <= {dout_f_1d,dout_r};
end

`ifdef SIMULATION
	wire	ctrl_rden_sel=1'b0;
`else
	wire	ctrl_rden_sel=1'b0;
`endif
reg		ctrl_rden;
always @(posedge Clk0)
begin
    ctrl_rden  <= app_rd_en_sft[15];
end
// determine correct read data valid signal timing
assign Sdr_rd_en = ctrl_rden_sel ? app_rd_en_sft[15] : ctrl_rden;

`endif








//////////////////////////////////////////////////////
localparam sta_idle	= 2'b00;
localparam sta_wrrd = 2'b01;
localparam sta_ref  = 2'b10;

reg	init_ref_vld_1d,ref_over,ref_vld;
reg	rw_vld_1d,sdr_op_over;
reg	wrrd_ref_ack,ref_ack;
reg [3:0] state = sta_idle;
////pipeline and refresh valid
always @(posedge Clk0)
begin
	init_ref_vld_1d <= Sdr_init_ref_vld;
	ref_over <= init_ref_vld_1d & (!Sdr_init_ref_vld);

	if(ref_over)
		ref_vld <= 1'b0;
	else if(Sdr_ref_req)
		ref_vld <= 1'b1;
end

always @(posedge Clk0)
begin
	rw_vld_1d <= rw_vld;
	sdr_op_over <= rw_vld_1d & (~rw_vld);
end

////refresh ack 
always @(posedge Clk0)
begin
	if(sdr_op_over)
		wrrd_ref_ack <= ref_vld;
	else
		wrrd_ref_ack <= 1'b0;
	
	if(Sdr_ref_req)
		if(!rw_vld)
			ref_ack <= 1'b1;
		else
			ref_ack <= 1'b0;
	else
		ref_ack <= 1'b0;
	
	Sdr_ref_ack <= (wrrd_ref_ack | ref_ack) & (~App_wr_en) & (~App_rd_en);
end

////////////////     state machine   ///////////////////////////////////////////////////////
always@(posedge Clk0)
begin
	if (Rst) 
		begin
			state <= sta_idle;
		end
	else
      (* FULL_CASE, PARALLEL_CASE *) case (state)
        sta_idle : 
				begin
					if(rw_vld)
						state <= sta_wrrd;
					else if(ref_vld)
						state <= sta_ref;
					else
						state <= sta_idle;
				end
        sta_wrrd : 	////sdr write and read
				begin
					if(sdr_op_over)
						if(ref_vld)
							state <= sta_ref;
						else
							state <= sta_idle;
					else
						state <= sta_wrrd;
				end
        sta_ref : 	////sdr refresh
				begin
					if(ref_over)
						state <= sta_idle;
					else
						state <= sta_ref;
				end	
		default:state <= sta_idle;
	endcase
end

////sdr operate state
always@(posedge Clk0)
begin
	if(Rst)
		Sdr_busy <= 1'b0;
	else if(state==sta_wrrd || state==sta_ref)
		Sdr_busy <= 1'b1;
	else
		Sdr_busy <= 1'b0;
end



// synthesis translate_off
reg  [8*20:1] state_ascii;
always @(state)
begin
  case (state)
    2'b00        : state_ascii <= #1 "sta_idle";
    2'b01        : state_ascii <= #1 "sta_wrrd";
    2'b10        : state_ascii <= #1 "sta_ref";
    default      : state_ascii <= #1 "sta_idle";
  endcase

end
// synthesis translate_on



endmodule


`pragma protect end
