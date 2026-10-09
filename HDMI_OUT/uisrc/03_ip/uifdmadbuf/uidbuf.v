`timescale 1ns / 1ns
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop: https://milianke.taobao.com
*Create Date: 2021/04/25
*Module Name:
*File Name:
*Description: 
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

module uidbuf#(
parameter  integer SDRAM_MAX_BURST_LEN 				= 256,      
parameter  integer                   VIDEO_ENABLE   = 1,  
parameter  integer                   ENABLE_WRITE   = 1,
parameter  integer                   ENABLE_READ    = 1,

parameter  integer                   AXI_DATA_WIDTH = 128,
parameter  integer                   AXI_ADDR_WIDTH = 32,

parameter  integer                   W_BUFDEPTH     = 2048,
parameter  integer                   W_DATAWIDTH    = 32,
parameter  [AXI_ADDR_WIDTH -1'b1: 0] W_BASEADDR     = 0,
parameter  integer                   W_DSIZEBITS    = 23,
parameter  integer                   W_XSIZE        = 1920, 
parameter  integer                   W_YSIZE        = 1080,
parameter  integer                   W_BUFSIZE      = 3,

parameter  integer                   R_BUFDEPTH     = 2048,
parameter  integer                   R_DATAWIDTH    = 32,
parameter  [AXI_ADDR_WIDTH -1'b1: 0] R_BASEADDR     = 0,
parameter  integer                   R_DSIZEBITS    = 23,
parameter  integer                   R_XSIZE        = 1920, 
parameter  integer                   R_YSIZE        = 1080,
parameter  integer                   R_BUFSIZE      = 3
)
(
input wire                                  ui_clk,
input wire                                  ui_rstn,
//sensor input -W_FIFO--------------
input wire                                  W_wclk_i,
input wire                                  W_FS_i,
input wire                                  W_wren_i,
input wire     [W_DATAWIDTH-1'b1 : 0]       W_data_i,
output reg     [7   :0]                     W_sync_cnt_o =0, 
input  wire    [7   :0]                     W_buf_i,
output wire                                 W_full,
//----------fdma signals write-------       
output wire    [AXI_ADDR_WIDTH-1'b1: 0]     fdma_waddr,
output wire                                 fdma_wareq,
output wire    [15  :0]                     fdma_wsize,                                     
input  wire                                 fdma_wbusy,		
output wire    [AXI_DATA_WIDTH-1'b1:0]      fdma_wdata,
input  wire                                 fdma_wvalid,
output wire                                 fdma_wready,
output reg     [7   :0]                     fmda_wbuf =0,
output wire                                 fdma_wirq,		
//----------fdma signals read-------  
input  wire                                 R_rclk_i,
input  wire                                 R_FS_i,
input  wire                                 R_rden_i,
output wire    [R_DATAWIDTH-1'b1 : 0]       R_data_o,
output reg     [7   :0]                     R_sync_cnt_o =0,
input  wire    [7   :0]                     R_buf_i,
output wire                                 R_empty,

output wire    [AXI_ADDR_WIDTH-1'b1: 0]     fdma_raddr,
output wire                                 fdma_rareq,
output wire    [15: 0]                      fdma_rsize,                                     
input  wire                                 fdma_rbusy,			
input  wire    [AXI_DATA_WIDTH-1'b1:0]      fdma_rdata,
input  wire                                 fdma_rvalid,
output wire                                 fdma_rready,
output reg     [7  :0]                      fmda_rbuf =0,
output wire                                 fdma_rirq
);    

function integer clog2;
  input integer value;
  begin 
    value = value-1;
    for (clog2=0; value>0; clog2=clog2+1)
      value = value>>1;
    end 
  endfunction
  
localparam S_IDLE  =  2'd0;  
localparam S_RST   =  2'd1;  
localparam S_DATA1 =  2'd2;   
localparam S_DATA2 =  2'd3; 


generate  if(ENABLE_WRITE == 1)begin : FDMA_WRITE_ENABLE
localparam FDMA_WX_BURST        =  SDRAM_MAX_BURST_LEN;
localparam WYBUF_SIZE           =  (W_BUFSIZE - 1'b1);
localparam WY_BURST_TIMES       =  (W_XSIZE*W_YSIZE*W_DATAWIDTH)/(FDMA_WX_BURST*AXI_DATA_WIDTH) - 1;
localparam WFIFO_DEPTH 			=   W_BUFDEPTH*W_DATAWIDTH/AXI_DATA_WIDTH;
localparam WX_BURST_ADDR_INC    =  (FDMA_WX_BURST*(AXI_DATA_WIDTH/8));

assign                                  fdma_wready = 1'b1;
reg                                     fdma_wareq_r= 1'b0;
reg                                     W_FIFO_Rst=0; 
wire                                    W_FS;
reg [1 :0]                              W_MS=0; 
reg [W_DSIZEBITS-1'b1:0]                W_addr=0; 
reg [15:0]                              W_bcnt=0; 
//wire[W_RD_DATA_COUNT_WIDTH-1'b1 :0]     W_rcnt;
wire                                     W_REQ; 
reg [5 :0]                              wirq_dly_cnt =0;
reg [7 :0]                              wrst_cnt =0;
reg [7 :0]                              fmda_wbufn;


assign fdma_wsize = FDMA_WX_BURST;
assign fdma_wirq = (wirq_dly_cnt>0);

assign fdma_waddr = W_BASEADDR + {fmda_wbufn,W_addr};

reg [1:0] W_MS_r =0;
always @(posedge ui_clk) W_MS_r <= W_MS;

always @(posedge ui_clk) begin
    if(ui_rstn == 1'b0)begin
        wirq_dly_cnt <= 6'd0;
        fmda_wbuf <=0;
    end
    else if((W_MS_r == S_DATA2) && (W_MS == S_IDLE))begin
        wirq_dly_cnt <= 60;
        fmda_wbuf <= fmda_wbufn;
    end
    else if(wirq_dly_cnt >0)
        wirq_dly_cnt <= wirq_dly_cnt - 1'b1;
end

fs_cap #
(
.VIDEO_ENABLE(VIDEO_ENABLE)
)
fs_cap_W0
(
 .clk_i(ui_clk),
 .rstn_i(ui_rstn),
 .vs_i(W_FS_i),
 .fs_cap_o(W_FS)
);

assign fdma_wareq = fdma_wareq_r;


 always @(posedge ui_clk) begin
    if(!ui_rstn)begin
        W_MS         <= S_IDLE;
        W_FIFO_Rst   <= 0;
        W_addr       <= 0;
        W_sync_cnt_o <= 0;
        W_bcnt       <= 0;
        wrst_cnt     <= 0;
        fmda_wbufn    <= 0;
        fdma_wareq_r <= 1'd0;
    end   
    else begin
      case(W_MS)
        S_IDLE:begin
          W_addr <= 0;
          W_bcnt <= 0;
          wrst_cnt <= 0;
          if(W_FS) begin
            W_MS <= S_RST;
            if(W_sync_cnt_o < WYBUF_SIZE)
                W_sync_cnt_o <= W_sync_cnt_o + 1'b1; 
            else 
                W_sync_cnt_o <= 0;  
          end
       end
       S_RST:begin
           fmda_wbufn <= W_buf_i;
           wrst_cnt <= wrst_cnt + 1'b1;
           if((VIDEO_ENABLE == 1) && (wrst_cnt < 60))
                W_FIFO_Rst <= 1;
           else if((VIDEO_ENABLE == 1) && (wrst_cnt < 100))
                W_FIFO_Rst <= 0;
           else if(fdma_wirq == 1'b0) begin
                W_MS <= S_DATA1;
           end
       end
        S_DATA1:begin 
          if(fdma_wbusy == 1'b0 && W_REQ )begin
             fdma_wareq_r  <= 1'b1; 
          end 
          else if(fdma_wbusy == 1'b1) begin
             fdma_wareq_r  <= 1'b0;
             W_MS    <= S_DATA2;
          end          
         end
        S_DATA2:begin 
            if(fdma_wbusy == 1'b0)begin
                if(W_bcnt == WY_BURST_TIMES)
                    W_MS <= S_IDLE;
                else begin
                	W_addr <= W_addr +  WX_BURST_ADDR_INC;  
                    W_bcnt <= W_bcnt + 1'b1;
                    W_MS    <= S_DATA1;
                end 
            end
         end
         default: W_MS <= S_IDLE; 
       endcase
    end
 end 


//wire W_rbusy;
//always@(posedge ui_clk)     
//     W_REQ  <= (W_rcnt > FDMA_WX_BURST - 2); 
     
     reg f2d_fifo_rst ;
 always @(posedge ui_clk) begin
 	f2d_fifo_rst <= (ui_rstn == 1'b0)|(W_FIFO_Rst);
 end
/* CVP修: W_REQ 原直接采 f2d_fifo 的 afull(写域 clk_125 信号), 与 ui_clk(150M)
 * 异步且无同步器 —— 偶发错采使突发请求错拍, 该拍陈旧数据写入 DDR(板上表现为
 * 跳动行)。两级同步后再用; afull 阈值距满溢余量充足, 2 拍延迟无害。 */
wire w_afull_raw;
reg  [1:0] w_req_sync = 2'b00;
always @(posedge ui_clk) w_req_sync <= {w_req_sync[0], w_afull_raw};
assign W_REQ = w_req_sync[1];
 
 
EG_LOGIC_FIFO #(
 	.DATA_WIDTH_W(W_DATAWIDTH),
	.DATA_WIDTH_R(AXI_DATA_WIDTH),
	.DATA_DEPTH_W(W_BUFDEPTH),
	.DATA_DEPTH_R(WFIFO_DEPTH),
	.ENDIAN("BIG"),
	.RESETMODE("ASYNC"),
	.E(0),
	.F(W_BUFDEPTH),
	.ASYNC_RESET_RELEASE("SYNC"),
	.AF(511))
f2d_fifo_inst(
	.rst(f2d_fifo_rst),
	.di(W_data_i),
	.clkw(W_wclk_i),
	.we(W_wren_i),
	.csw(3'b111),
	.do(fdma_wdata),
	.clkr(ui_clk),
	.re(fdma_wvalid),
	.csr(3'b111),
	.ore(1'b0),
	.empty_flag(empty_flag),
	.aempty_flag(),
	.full_flag(full_flag),
	.afull_flag(w_afull_raw)
);

 
end
else begin : FDMA_WRITE_DISABLE

//----------fdma signals write-------       
assign fdma_waddr = 0;
assign fdma_wareq = 0;
assign fdma_wsize = 0;                                   	
assign fdma_wdata = 0;
assign fdma_wready = 0;
assign fdma_wirq = 0;	
assign W_full = 0;

end
endgenerate


generate  if(ENABLE_READ == 1)begin : FDMA_READ
localparam FDMA_RX_BURST        =  SDRAM_MAX_BURST_LEN;
localparam RYBUF_SIZE           = (R_BUFSIZE - 1'b1);
localparam RY_BURST_TIMES       = (R_XSIZE*R_YSIZE*R_DATAWIDTH)/(FDMA_RX_BURST*AXI_DATA_WIDTH) - 1;
localparam RFIFO_DEPTH 			=  R_BUFDEPTH*R_DATAWIDTH/AXI_DATA_WIDTH;//R_BUFDEPTH/(AXI_DATA_WIDTH/R_DATAWIDTH);
localparam RX_BURST_ADDR_INC    = (FDMA_RX_BURST*(AXI_DATA_WIDTH/8));

assign                                  fdma_rready = 1'b1;
reg                                     fdma_rareq_r= 1'b0;
reg                                     R_FIFO_Rst=0; 
wire                                    R_FS;
reg [1 :0]                              R_MS=0; 
reg [R_DSIZEBITS-1'b1:0]                R_addr=0; 
reg [15:0]                              R_bcnt=0; 
//wire[R_WR_DATA_COUNT_WIDTH-1'b1 :0]     R_wcnt;
wire                                     R_REQ; 
reg [5 :0]                              rirq_dly_cnt =0;
reg [7 :0]                              rrst_cnt =0;
reg [7 :0]                              fmda_rbufn;
assign fdma_rsize = FDMA_RX_BURST;
assign fdma_rirq = (rirq_dly_cnt>0);

assign fdma_raddr = R_BASEADDR + {fmda_rbufn,R_addr};

reg [1:0] R_MS_r =0;
always @(posedge ui_clk) R_MS_r <= R_MS;

always @(posedge ui_clk) begin
    if(ui_rstn == 1'b0)begin
        rirq_dly_cnt <= 6'd0;
        fmda_rbuf <=0;
    end
    else if((R_MS_r == S_DATA2) && (R_MS == S_IDLE))begin
        rirq_dly_cnt <= 60;
        fmda_rbuf <= fmda_rbufn;
    end
    else if(rirq_dly_cnt >0)
        rirq_dly_cnt <= rirq_dly_cnt - 1'b1;
end

fs_cap #
(
.VIDEO_ENABLE(VIDEO_ENABLE)
)
fs_cap_R0
(
  .clk_i(ui_clk),
  .rstn_i(ui_rstn),
  .vs_i(R_FS_i),
  .fs_cap_o(R_FS)
);

assign fdma_rareq = fdma_rareq_r;

 always @(posedge ui_clk) begin
   if(!ui_rstn)begin
        R_MS          <= S_IDLE;
        R_FIFO_Rst   <= 0;
        R_addr       <= 0;
        R_sync_cnt_o <= 0;
        R_bcnt       <= 0;
        rrst_cnt     <= 0;
        fmda_rbufn    <= 0;
        fdma_rareq_r  <= 1'd0;
    end   
    else begin
      case(R_MS)
        S_IDLE:begin
          R_addr <= 0;
          R_bcnt <= 0;
          rrst_cnt <= 0;
          if(R_FS) begin
            R_MS <= S_RST;
            if(R_sync_cnt_o < RYBUF_SIZE)
                R_sync_cnt_o <= R_sync_cnt_o + 1'b1; 
            else 
                R_sync_cnt_o <= 0;  
          end
       end
       S_RST:begin
           fmda_rbufn <= R_buf_i;
           rrst_cnt <= rrst_cnt + 1'b1;
           if((VIDEO_ENABLE == 1) && (rrst_cnt < 60))
                R_FIFO_Rst <= 1;
           else if((VIDEO_ENABLE == 1) && (rrst_cnt < 100))
                R_FIFO_Rst <= 0;
           else if(fdma_rirq == 1'b0) begin
                R_MS <= S_DATA1;
           end
       end
       S_DATA1:begin 
         if(fdma_rbusy == 1'b0 && R_REQ)begin
            fdma_rareq_r  <= 1'b1;  
         end
         else if(fdma_rbusy == 1'b1) begin
            fdma_rareq_r  <= 1'b0;
            R_MS    <= S_DATA2;
         end         
        end
        S_DATA2:begin 
            if(fdma_rbusy == 1'b0)begin
                if(R_bcnt == RY_BURST_TIMES)
                    R_MS <= S_IDLE;
                else begin
                	R_addr <= R_addr +  RX_BURST_ADDR_INC;  
                    R_bcnt <= R_bcnt + 1'b1;
                    R_MS    <= S_DATA1;
                end 
            end
         end
         default:R_MS <= S_IDLE;
      endcase
   end
end 

//wire R_wbusy;
//always@(posedge ui_clk)      
//     R_REQ  <= (R_wcnt < FDMA_RX_BURST - 2);
reg d2f_fifo_rst ;
 always @(posedge ui_clk) begin
 	d2f_fifo_rst <= (ui_rstn == 1'b0)|(R_FIFO_Rst);
 end
/* CVP修: R_REQ 原直接采 d2f_fifo 的 aempty(读域 pclkx1 75M 信号), 与 ui_clk(150M)
 * 异步且无同步器(150/75 边沿对齐使 STA 未报, 物理漂移下仍会错采) —— 预取请求
 * 延迟/提前, 显示段读空取到陈旧数据(板上表现为撕裂)。两级同步; aempty 距真空
 * 余量充足且 2 拍远小于 DMA 仲裁延迟, 无害。 */
wire r_aempty_raw;
reg  [1:0] r_req_sync = 2'b00;
always @(posedge ui_clk) r_req_sync <= {r_req_sync[0], r_aempty_raw};
assign R_REQ = r_req_sync[1];


EG_LOGIC_FIFO #(
 	.DATA_WIDTH_W(AXI_DATA_WIDTH),
	.DATA_WIDTH_R(R_DATAWIDTH),
	.DATA_DEPTH_W(RFIFO_DEPTH),
	.DATA_DEPTH_R(R_BUFDEPTH),
	.ENDIAN("BIG"),
	.RESETMODE("ASYNC"),
	.E(0),
	.F(RFIFO_DEPTH),
	.ASYNC_RESET_RELEASE("SYNC"),
	.AE(511))
d2f_fifo_inst(
	.rst(d2f_fifo_rst),
	.di(fdma_rdata),
	.clkw(ui_clk),
	.we(fdma_rvalid),
	.csw(3'b111),
	.do(R_data_o),
	.clkr(R_rclk_i),
	.re(R_rden_i),
	.csr(3'b111),
	.ore(1'b0),
	.empty_flag(empty_flag),
	.aempty_flag(r_aempty_raw),
	.full_flag(full_flag),
	.afull_flag()

);


end
else begin : FDMA_READ_DISABLE
   
assign fdma_raddr = 0;
assign fdma_rareq = 0;
assign fdma_rsize = 0;                                   	
assign fdma_rready = 0;
assign fdma_rirq = 0;	
assign R_empty = 1'b0;
assign R_data_o =0;
end
endgenerate

endmodule

