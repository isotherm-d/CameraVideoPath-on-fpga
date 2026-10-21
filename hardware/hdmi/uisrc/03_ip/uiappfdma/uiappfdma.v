
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2022/05/15
*File Name: 
*Description: 
*Declaration:
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) _i input
*2) _o output
*3) _n activ low
*4) _dg debug signal 
*5) _r delay or register
*6) _s state mechine
*********************************************************************/
`timescale 1ns / 1ps


module app_fdma#
(
  parameter  integer SDRAM_MAX_BURST_LEN = 256   
)
(
input   wire            				   	fdma_clk       		,
input   wire            				   	fdma_rstn         	,
//===========fdma interface=======
input   wire [23: 0]      					fdma_waddr          ,
input   wire  	                            fdma_wareq          ,
input   wire [15: 0]                      	fdma_wsize          ,                                     
output  reg                                 fdma_wbusy          ,
				
input   wire [31 :0]       					fdma_wdata			,
output  wire                               	fdma_wvalid         ,
//input	wire                               	fdma_wready			,

input   wire [23: 0]      					fdma_raddr          ,
input   wire                                fdma_rareq          ,
input   wire [15: 0]                      	fdma_rsize          ,                                     
output  reg                                 fdma_rbusy          ,
				
output  wire [31 :0]       					fdma_rdata			,
output  wire                               	fdma_rvalid         ,
//input	wire                               	fdma_rready			,
//===========ddr interface===============
input	wire								sdr_init_done   	,
input	wire								sdr_init_ref_vld	,
	
output	reg   								app_wr_en       	,
output 	reg  [22 :0]						app_wr_addr     	, 
output 	wire [1  :0]						app_wr_dm       	,
output 	wire [31 :0]						app_wr_din     	 	,
	
output	reg 								app_rd_en       	,
output 	reg  [22 :0]						app_rd_addr     	,
input	wire 								sdr_rd_en       	,
input  	wire [31 :0]						sdr_rd_dout         ,
input   wire  								sdr_busy
);

localparam S_IDLE       = 2'h0;
localparam S_WRITE      = 2'h1;
localparam S_READ      	= 2'h2;
localparam S_READ_END   = 2'h3;
reg [1 :0]state;

//**************FDMA WRITE  BURST*******************
reg [21:0]wr_addr;
reg wr_en;
wire wlast,w_next,fdma_wend;

reg [15:0] wburst_cnt=0;
reg [15:0] wburst_len=0;
reg [15:0] wfdma_cnt=0;
reg [15:0] fdma_wleft_cnt=0;

assign w_next = wr_en;
//waddr set
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)
    	wr_addr <= 0;
	else if((fdma_wareq==1'b1)&&(state==S_IDLE))
		wr_addr <= fdma_waddr[23:2];
	else if(w_next)
		wr_addr[21:0] <= wr_addr[21 :0] + 1'b1; 

//wburst counter
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)
    	wburst_cnt <= 0;
	else if((fdma_wbusy==1'b1)&&(state==S_IDLE))
		wburst_cnt <= 0;
	else if(w_next)
		wburst_cnt <= wburst_cnt + 1'b1;    
//wburst last data       	
assign wlast = (w_next == 1'b1) && (wburst_cnt == (wburst_len-1));


//fdma left lenth
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)begin
		wfdma_cnt 	   <= 0;
		fdma_wleft_cnt <= 0;
	end
	else if(fdma_wareq==1'b1)begin
		wfdma_cnt <= 0;
		fdma_wleft_cnt <= fdma_wsize;
	end
	else if(w_next)begin
		wfdma_cnt <= wfdma_cnt + 1'b1;	
	    fdma_wleft_cnt <= (fdma_wsize - 1'b1) - wfdma_cnt;
    end
    
//fdma burst end
assign  fdma_wend = w_next && (fdma_wleft_cnt == 1 );

//wburst len set
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)begin
		wburst_len <= 1;
	end
    else if((fdma_wbusy==1'b1)&&(state==S_IDLE))begin
        if(fdma_wleft_cnt[15:8] >0)  
			wburst_len <= SDRAM_MAX_BURST_LEN;
        else 
            wburst_len <= fdma_wleft_cnt[7:0];
    end
    else wburst_len <= wburst_len;


//**************FDMA read  BURST*******************
reg [21:0]rd_addr;
reg rd_en;
wire rlast,r_next,fdma_rend;

reg [15:0] rburst_cnt=0;
reg [15:0] rburst_len=0;
reg [15:0] rfdma_cnt=0;
reg [15:0] fdma_rleft_cnt=0;

assign r_next = rd_en;
//waddr set
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)
    	rd_addr <= 0;
	else if((fdma_rareq==1'b1)&&(state==S_IDLE))
		rd_addr <= fdma_raddr[23:2];
	else if(r_next)
		rd_addr[21 :0] <= rd_addr[21 :0] + 1'b1; 

//wburst counter
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)
    	rburst_cnt <= 0;
	else if((fdma_rbusy==1'b1)&&(state==S_IDLE))
		rburst_cnt <= 0;
	else if(r_next)
		rburst_cnt <= rburst_cnt + 1'b1;    
//wburst last data       	
assign rlast = (r_next == 1'b1) && (rburst_cnt == (rburst_len-1));


//fdma left lenth
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)begin
		rfdma_cnt 	   <= 0;
		fdma_rleft_cnt <= 0;
	end
	else if(fdma_rareq==1'b1)begin
		rfdma_cnt <= 0;
		fdma_rleft_cnt <= fdma_rsize;
	end
	else if(r_next)begin
		rfdma_cnt <= rfdma_cnt + 1'b1;	
	    fdma_rleft_cnt <= (fdma_rsize - 1'b1) - rfdma_cnt;
    end
    
//fdma burst end
assign  fdma_rend = r_next && (fdma_rleft_cnt == 1 );

//wburst len set
always@(posedge fdma_clk or negedge fdma_rstn)
	if(fdma_rstn == 1'b0)
		rburst_len <= 1;
    else if((fdma_rbusy==1'b1)&&(state==S_IDLE))begin
        if(fdma_rleft_cnt[15:8] >0)  
			rburst_len <= SDRAM_MAX_BURST_LEN;
        else 
            rburst_len <= fdma_rleft_cnt[7:0];
    end
    else
    	rburst_len <= rburst_len;


//**************Continuous balanced read and write strategy*******************    
reg fdma_rareq_r;   
 
always@(posedge fdma_clk or negedge fdma_rstn)begin
	if(fdma_rstn == 1'b0)begin
    	wr_en		  <= 0;
        fdma_wbusy 	  <= 0;
        rd_en         <= 0;	
        fdma_rbusy    <= 0;
        fdma_rareq_r  <= 0;
        state         <= 0;
	end
	else begin
		case(state)
			S_IDLE:begin
			if(fdma_wareq) fdma_wbusy <= 1'b1;
			if(fdma_rareq) fdma_rbusy <= 1'b1;
            	if({sdr_busy,fdma_rareq_r,fdma_wbusy}==3'b001)begin
                    fdma_rareq_r 	<= fdma_rareq|fdma_rbusy;
                    state  			<= S_WRITE;
                end
                else if({sdr_busy,fdma_rbusy}==2'b01)begin
                    fdma_rareq_r 	<= 1'b0;
                    state  			<= S_READ;
                end
			end
            S_WRITE:begin
				if(fdma_wend == 1'b1)begin
                	wr_en   		<= 1'b0;
                    fdma_wbusy 		<= 1'b0;
                    state 			<= S_IDLE;
                end
                else if(wlast == 1'b1)begin
                    wr_en   		<= 1'b0;
                    state 			<= S_IDLE;
				end
				else begin
					wr_en   		<= 1'b1;
                    state 			<= S_WRITE;
				end
			end 
            S_READ:begin
				if(fdma_rend == 1'b1)begin
                	rd_en   		<= 1'b0;
                    state 			<= S_READ_END;
                end
                else if(rlast == 1'b1)begin
                    rd_en   		<= 1'b0;
                    state 			<= S_IDLE;
				end
				else begin
					rd_en   		<= 1'b1;
                    state 			<= S_READ;
				end
			end  
            S_READ_END:begin
            	   if(sdr_busy == 1'b0)begin
            	   fdma_rbusy 		<= 1'b0;
                   state 			<= S_IDLE;
                   end
            end
                        
			default:state <= S_IDLE;
		endcase
	end
end

assign fdma_wvalid  = wr_en;//For anlogic FPGA, fdma_wvalid will be one cycle earlier than data
assign app_wr_din   = fdma_wdata ;
assign app_wr_dm    =2'b00;
assign fdma_rvalid  = sdr_rd_en;
assign fdma_rdata   = sdr_rd_dout;

always@(posedge fdma_clk or negedge fdma_rstn)
begin
	if(fdma_rstn == 1'b0)
	begin
		app_wr_en   <= 'd0;
		app_wr_addr <= 'd0;
		app_rd_en   <= 'd0;
		app_rd_addr <= 'd0;
	end
	else if(sdr_init_done == 1'b1)
	begin
		app_wr_en   <= wr_en     ;
		app_wr_addr <= {wr_addr,1'b0}   ;
		app_rd_en   <= rd_en     ;
		app_rd_addr <= {rd_addr,1'b0}    ;
	end
	else
	begin
		app_wr_en   <= 'd0;
		app_wr_addr <= 'd0;
		app_rd_en   <= 'd0;
		app_rd_addr <= 'd0;
	end
end




endmodule

