
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2019/12/17
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
`timescale 1ns / 1ns

module uivtc#
(
parameter H_ActiveSize  =   1920,               //视频时间参数,行视频信号，一行有效(需要显示的部分)像素所占的时钟数，一个时钟对应一个有效像素
parameter H_FrameSize   =   1920+88+44+148,     //视频时间参数,行视频信号，一行视频信号总计占用的时钟数
parameter H_SyncStart   =   1920+88,            //视频时间参数,行同步开始，即多少时钟数后开始产生行同步信号 
parameter H_SyncEnd     =   1920+88+44,         //视频时间参数,行同步结束，即多少时钟数后停止产生行同步信号，之后就是行有效数据部分

parameter V_ActiveSize  =   1080,               //视频时间参数,场视频信号，一帧图像所占用的有效(需要显示的部分)行数量，通常说的视频分辨率即H_ActiveSize*V_ActiveSize
parameter V_FrameSize   =   1080+4+5+36,        //视频时间参数,场视频信号，一帧视频信号总计占用的行数量
parameter V_SyncStart   =   1080+4,             //视频时间参数,场同步开始，即多少行数后开始产生场同步信号 
parameter V_SyncEnd     =   1080+4+5            //视频时间参数,场同步结束，即多少场数后停止产生场同步信号，之后就是场有效数据部分
)
(
input           I_vtc_rstn,//系统复位
input			I_vtc_clk,//系统时钟
output	reg		O_vtc_vs,//场同步输出
output  reg     O_vtc_hs,//行同步输出
output  reg     O_vtc_de//视频数据有效 
);

reg [11:0] hcnt = 12'd0;    //视频水平方向，列计数器，寄存器
reg [11:0] vcnt = 12'd0;    //视频垂直方向，行计数器，寄存器   
reg [2 :0] rst_cnt = 3'd0;  //复位计数器，寄存器
wire rst_sync = rst_cnt[2]; //同步复位

//通过计数器产生同步复位
always @(posedge I_vtc_clk)begin
    if(!I_vtc_rstn)
        rst_cnt <= 3'd0;
    else if(rst_cnt[2] == 1'b0)
        rst_cnt <= rst_cnt + 1'b1;
end    

//视频水平方向，列计数器
always @(posedge I_vtc_clk)begin
    if(rst_sync == 1'b0) //复位
        hcnt <= 12'd0;
    else if(hcnt < (H_FrameSize - 1'b1))//计数范围从0 ~ H_FrameSize-1
        hcnt <= hcnt + 1'b1;
    else 
        hcnt <= 12'd0;
end   

//视频垂直方向，行计数器，用于计数已经完成的行视频信号
always @(posedge I_vtc_clk)begin
    if(rst_sync == 1'b0)
        vcnt <= 12'd0;
    else if(hcnt == (H_ActiveSize  - 1'b1)) begin//视频水平方向，是否一行结束
           vcnt <= (vcnt == (V_FrameSize - 1'b1)) ? 12'd0 : vcnt + 1'b1;//视频垂直方向，行计数器加1，计数范围0~V_FrameSize - 1
    end
end 

wire hs_valid  =  hcnt < H_ActiveSize; //行信号有效像素部分
wire vs_valid  =  vcnt < V_ActiveSize; //场信号有效像素部分
wire vtc_hs    =  (hcnt >= H_SyncStart && hcnt < H_SyncEnd);//产生hs，行同步信号
wire vtc_vs    =  (vcnt > V_SyncStart && vcnt <= V_SyncEnd);//产生vs，场同步信号      
wire vtc_de    =  hs_valid && vs_valid;//只有当视频水平方向，列有效和视频垂直方向，行同时有效，视频数据部分才是有效

always @(posedge I_vtc_clk)begin
	if(rst_sync == 1'b0)begin
		O_vtc_vs <= 1'b0;
		O_vtc_hs <= 1'b0;
		O_vtc_de <= 1'b0;
	end
	else begin
		O_vtc_vs <= vtc_vs;
		O_vtc_hs <= vtc_hs;
		O_vtc_de <= vtc_de;	
	end
end

endmodule


