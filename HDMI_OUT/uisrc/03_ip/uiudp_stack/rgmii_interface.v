
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2022/12/23
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.1
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*******************************rgmii_interfaceģ*********************
--Ƶrgmii_interfaceģ
ģʵRGMIIתGMIIӿڣ֧10M/100M/1000Mת
*********************************************************************/


/* CVP修: RX_CLK_PHASE_SEL 选择 IDDR 采样时钟相位
 *   0 = PLL2 clk0 (相位0, 例程原始, 匹配PHY=延迟strap模式)
 *   1 = PLL2 clk1 (滞后2ns, 匹配PHY=无延迟strap, 数据眼中心采样) */
module rgmii_interface #(
    parameter integer RX_CLK_PHASE_SEL = 1
)(
// ָʾǰٶΪ10/100
input            speed_10_100,   //õǰ
//RGMIIʱPHY FPGATXźţûʹڲ2nsӳҪfpga2nsӳ
input			     gmii_tx_clk_d,    
input			     gmii_tx_reset_d,   
// ¶˿RGMIIӿڣЩ˿ڽλFPGA
output     [3:0] rgmii_txd,
output           rgmii_tx_ctl,
output           rgmii_txc,

input      [3:0] rgmii_rxd,
input            rgmii_rx_ctl,
input            rgmii_rxc,
// ¶˿ӵ TEMAC  ڲGMIIӿģ
input            gmii_tx_reset,
input            gmii_tx_clk,      // ggmii_tx_clk: 125mhz
input      [7:0] gmii_txd,
input            gmii_tx_en,
input            gmii_tx_er,

input            gmii_rx_reset,
output               gmii_rx_clk,    //output 125mhz1gbps 25mhz(100mbps)    2.5mhz(10mbps)
output reg    [7:0] gmii_rxd,
output reg          gmii_rx_dv,
output reg          gmii_rx_er,

output           gmii_crs,
output           gmii_col,
// źΪRGMII״̬ź
output reg       link_status,
output reg [1:0] clock_speed,
output reg       duplex_status,

// CVP调试: 前导窗口(帧头12字节内)特征字节计数
output reg [11:0] o_dbg_cnt55,
output reg [11:0] o_dbg_cntd5,
output reg [11:0] o_dbg_cntaa,
output reg [11:0] o_dbg_cnt5d,

// CVP修: 采样时钟引出(下游 rgmii_cdc 必须与 gmii_rxd/gmii_rx_dv 同域!)
output wire       o_gmii_rx_sample_clk
);
//----------------------------------------------------------------------------
// ģ ڲ ź
//----------------------------------------------------------------------------
reg    [3:0] gmii_txd_falling;             // gmii_txdźgmii_tx_clk½档
wire         rgmii_txc_odelay;             // RGMIIʱODDR.
wire         rgmii_tx_ctl_odelay;          // RGMIIźODDR.
wire   [3:0] rgmii_txd_odelay;             // RGMIIODDR.
wire         rgmii_tx_ctl_int;             // ڲRGMIIź.
wire         rgmii_rx_ctl_delay;
wire   [3:0] rgmii_rxd_delay;
wire         rgmii_rx_ctl_reg;             // ڲRGMIIź.

reg          tx_en_to_ddr;

wire         gmii_rx_dv_reg;               
wire         gmii_rx_er_reg;               
wire   [7:0] gmii_rxd_reg;                 

wire         inband_ce;                    //RGMII״̬Ĵ ʹź
wire         rgmii_rxc_int;


//==============================================================================
// RGMII ߼
//==============================================================================

//----------------------------------------------------------------------------
// RGMII ʱӹrgmii_txc
//----------------------------------------------------------------------------
//  rgmii_txc ʱ.
EG_LOGIC_ODDR  rgmii_txc_ddr 
(
.q             (rgmii_txc_odelay), //output 125mhz1gbps 25mhz(100mbps)    2.5mhz(10mbps)
.clk           (gmii_tx_clk_d),
.d0            (1'b1),
.d1            (1'b0),
.rst           (gmii_tx_reset_d)
);

// ʱ2ns,Ա㽫ʱӱؼrgmii_txd [30]Чڡ0.285ns
// EG_LOGIC_ODELAY 
// #(
// .OUTDEL  (1)
// )
// delay_rgmii_gmii_tx_clk 
// (
// .i       (rgmii_txc_odelay),
// .o       (rgmii_txc)     //output 125mhz1gbps 25mhz(100mbps)    2.5mhz(10mbps)
// );
assign rgmii_txc = rgmii_txc_odelay;
   
//---------------------------------------------------------------------------
// RGMII ߼ : rgmii_txd
//---------------------------------------------------------------------------
// 1Gbps gmii_txd  8λЧ; rgmii_txc˫ʹܷ8λ
// 10/100Mbps gmii_txd λЧrgmii_txc˫ʹظ͵λ
// 1Gbpsʱ125mhzrgmii_txcط͵λ½ط͸λ һʱ8bit, 125*8=1Gbps
// 100Mbpsʱ25mhzrgmii_txcط͵λ½ط͵λ ൱һʱֻһ4bit, 25*4=100mbps
// 10Mbpsʱͬ100mbps,ЧλÿbyteĵλȻһʱظλ൱һʱֻһ4λ
	
always @ (speed_10_100, gmii_txd)begin
   if (speed_10_100 == 1'b0) // 1Gbps gmii_txd  8λЧ
	  gmii_txd_falling     <= gmii_txd[7:4];
   else      // 10/100Mbps gmii_txdλЧrgmii_txc˫ʹܷ͵λ
	  gmii_txd_falling     <= gmii_txd[3:0];
end

genvar i;
generate for (i=0; i<4; i=i+1)begin : txdata_out_bus
EG_LOGIC_ODDR  rgmii_txd_out 
      (
      .q             (rgmii_txd_odelay[i]),
      .clk           (gmii_tx_clk),
      .d0            (gmii_txd[i]),
      .d1            (gmii_txd_falling[i]),
      .rst           (gmii_tx_reset)
      );
// ӳ 2 ns 棺0.175ns
// EG_LOGIC_ODELAY 
// #(
// .OUTDEL  (0)
// )
// delay_rgmii_txd (
// .i  (rgmii_txd_odelay[i]),
// .o       (rgmii_txd[i])
// );
assign rgmii_txd[i] = rgmii_txd_odelay[i];
end
endgenerate


//---------------------------------------------------------------------------
// RGMII ߼ : rgmii_tx_ctl
//---------------------------------------------------------------------------
//  rgmii ctl ź
assign rgmii_tx_ctl_int = gmii_tx_en ^ gmii_tx_er;

// Ҫ߼ȷ ź ʱλڣtx_ctlΪ͵ƽ
always @(speed_10_100 or gmii_tx_en or gmii_tx_er)begin
   if (speed_10_100)
	  tx_en_to_ddr = gmii_tx_en & (!gmii_tx_er );
   else
	  tx_en_to_ddr = gmii_tx_en;
end
	
// oDDR primitive
EG_LOGIC_ODDR  ctl_output 
(
.q             (rgmii_tx_ctl_odelay),
.clk           (gmii_tx_clk),
.d0            (tx_en_to_ddr),
.d1            (rgmii_tx_ctl_int),
.rst           (gmii_tx_reset)
);

// ӳ 2 ns 棺0.175ns
// EG_LOGIC_ODELAY 
// #(
// .OUTDEL  (0)
// )
// delay_rgmii_tx_ctl 
// (
// .i       (rgmii_tx_ctl_odelay),
// .o       (rgmii_tx_ctl)
// );
assign rgmii_tx_ctl = rgmii_tx_ctl_odelay;

//==============================================================================
// RGMII ߼
//==============================================================================

//---------------------------------------------------------------------------
// RGMII ߼rgmii_rxc
//---------------------------------------------------------------------------

//EG_PHY_GCLK u_rgmii_rxc 
//(
//.clki (rgmii_rxc),
//.clko (gmii_rx_clk)
//);

//DR1_PHY_LCLK u_gmii_rx_clk
//(
//.ce        (1'b1        ),
//.clkin     (rgmii_rxc   ),
//.rst       (1'b0        ),
//.clkout    (gmii_rx_clk ),
//.clkdivout (     )
//);

PLL2 PLL2
(
   .refclk   (rgmii_rxc),
   .reset    (0),
   .extlock  (),
   .clk0_out (gmii_rx_clk),
   .clk1_out (rgmii_rxc_int)
);

// CVP修: RX 采样时钟 = clk0(原始相位) 或 clk1(滞后2ns, 眼中心)
wire gmii_rx_sample_clk = (RX_CLK_PHASE_SEL == 1) ? rgmii_rxc_int : gmii_rx_clk;
assign o_gmii_rx_sample_clk = gmii_rx_sample_clk;

/*
ʹ´ʵͨţǴڶ
PH1_PHY_SCLK_V2 u_rgmii_rxc 
(
.ce(1'b1),
.clkin (rgmii_rxc),
.clkout (gmii_rx_clk)
);

// [CVP删除] 原 assign rgmii_rxc_int = gmii_rx_clk; 与 PLL2 clk1 输出多驱动冲突, 且使相移失效
*/
//assign   gmii_rx_clk  = rgmii_rxc_int;  // ڲźŸ˿
   
   
//---------------------------------------------------------------------------
// RGMII ߼rgmii_rxd ---->  gmii_rxd_reg
//---------------------------------------------------------------------------
// 1Gbps gmii_rxd  8λЧ; rgmii_rxc˫ʹܽ8λ
// 10/100Mbps gmii_rxd λЧrgmii_rxc˫ʹܽոߵλͬ
// 1gbpsʱ125mhzrgmii_rxcؽλݣӦ4bit½ؽλݣӦ4bit һʱ8bit, 125mhz*8=1gbps
// 100mbpsʱ25mhzrgmii_rxcؽλݣ½ؽλݣλ͵λͬ ൱ڵزһʱֻһ4bitЧλÿbyteĵλߵλظ, 25mhz*4=100mbps
// 10mbpsʱͬ100mbps,Ȼһʱظͬλݣ൱һʱֻһ4bit

genvar j;
generate for (j=0; j<4; j=j+1)begin : rxdata_bus
	
// EG_LOGIC_IDELAY delay_rgmii_rxd 
// (
// .i       (rgmii_rxd[j]),
// .o       (rgmii_rxd_delay[j])
// );

assign rgmii_rxd_delay[j]=rgmii_rxd[j];
end
endgenerate

// Instantiate Double Data Rate Input flip-flops.
// DDR_CLK_EDGE attribute specifies output data alignment from IDDR component
genvar k;
generate for (k=0; k<4; k=k+1)begin : rxdata_in_bus 
EG_LOGIC_IDDR rgmii_rx_data_in 
(
.q0            (gmii_rxd_reg[k]),
.q1            (gmii_rxd_reg[k+4]),
.clk           (gmii_rx_sample_clk),
.d             (rgmii_rxd_delay[k]),
.rst           (1'b0)
);

	 
end
endgenerate
   
//---------------------------------------------------------------------------
// RGMII ߼rgmii_rx_ctl ------> gmii_rx_dvgmii_rx_er
//---------------------------------------------------------------------------
	
// EG_LOGIC_IDELAY delay_rgmii_rx_ctl 
// (
// .i       (rgmii_rx_ctl),
// .o       (rgmii_rx_ctl_delay)
// );
assign rgmii_rx_ctl_delay = rgmii_rx_ctl;
 
EG_LOGIC_IDDR rgmii_rx_ctl_in 
(
.q0            (gmii_rx_dv_reg),
.q1            (rgmii_rx_ctl_reg),
.clk           (gmii_rx_sample_clk),
.d             (rgmii_rx_ctl_delay),
.rst           (1'b0)
);


//  gmii_rx_er signal
assign gmii_rx_er_reg = gmii_rx_dv_reg ^ rgmii_rx_ctl_reg;


//----------------------------------------------------------------------------
// ߼ڲźŸ˿ڣgmii_rxdgmii_rx_dvgmii_rx_ergmii_colgmii_crs
//----------------------------------------------------------------------------

//assign gmii_rxd      = gmii_rxd_reg;
//assign gmii_rx_dv    = gmii_rx_dv_reg;
//assign gmii_rx_er    = gmii_rx_er_reg;

always @ (posedge gmii_rx_sample_clk  )begin
gmii_rxd      <= gmii_rxd_reg;
gmii_rx_dv    <= gmii_rx_dv_reg;
gmii_rx_er    <= gmii_rx_er_reg;    
end

// RGMIIGMIIʽĳͻزź 
assign gmii_col = (gmii_tx_en | gmii_tx_er) & (gmii_rx_dv_reg | gmii_rx_er_reg);
assign gmii_crs = (gmii_tx_en | gmii_tx_er) | (gmii_rx_dv_reg | gmii_rx_er_reg);
  
  

//==============================================================================
// RGMII ״̬Ĵ
//==============================================================================

// ֡ڼô״̬Ĵ
   

/* CVP调试: 帧头窗口特征字节计数 —— 判读字节流形态
 * 正常流: 55 前导(7/帧)+D5 SFD(1/帧), AA/5D≈0
 * nibble交换: 55→AA, D5→5D;  相位错: 四者皆≈0 */
reg [3:0] dbg_bcnt;
reg       dbg_dv_d;
always @ (posedge gmii_rx_sample_clk or posedge gmii_rx_reset) begin
    if (gmii_rx_reset) begin
        dbg_bcnt <= 4'd0;  dbg_dv_d <= 1'b0;
        o_dbg_cnt55 <= 12'd0; o_dbg_cntd5 <= 12'd0;
        o_dbg_cntaa <= 12'd0; o_dbg_cnt5d <= 12'd0;
    end else begin
        dbg_dv_d <= gmii_rx_dv_reg;
        if (gmii_rx_dv_reg && !dbg_dv_d)          // rvalid 上升沿: 开窗
            dbg_bcnt <= 4'd0;
        else if (gmii_rx_dv_reg && dbg_bcnt < 4'd12)
            dbg_bcnt <= dbg_bcnt + 4'd1;
        if (gmii_rx_dv_reg && dbg_bcnt < 4'd12) begin
            case (gmii_rxd_reg)
                8'h55: o_dbg_cnt55 <= o_dbg_cnt55 + 12'd1;
                8'hd5: o_dbg_cntd5 <= o_dbg_cntd5 + 12'd1;
                8'haa: o_dbg_cntaa <= o_dbg_cntaa + 12'd1;
                8'h5d: o_dbg_cnt5d <= o_dbg_cnt5d + 12'd1;
                default: ;
            endcase
        end
    end
end

assign inband_ce = !(gmii_rx_dv_reg || gmii_rx_er_reg);

always @ (posedge gmii_rx_clk  or posedge gmii_rx_reset)begin
   if (gmii_rx_reset) begin
	  link_status          <= 1'b0;
	  clock_speed[1:0]     <= 2'b0;
	  duplex_status        <= 1'b0;
   end
   else if (inband_ce) begin
	  link_status          <= gmii_rxd_reg[0];
	  clock_speed[1:0]     <= gmii_rxd_reg[2:1];
	  duplex_status        <= gmii_rxd_reg[3];
   end
end


endmodule

