

module design_top_wrapper (
    input wire        I_sys_clk,
    input wire        I_rst_n,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [1:0]  I_button,

    output wire       O_screen_pwm,

    output wire       O_uart_tx,

    // ---- CAM CHECK/NET: 以太网调试通路 (ETHA, YT8531, RGMII 千兆) ----
    output wire [3:0] O_eth_rgmii_txd,
    output wire       O_eth_rgmii_tx_ctl,
    output wire       O_eth_rgmii_txc,
    output wire       O_eth_mdc,
    inout  wire       IO_eth_mdio,
    output wire       O_eth_rst_n,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    inout wire        IO_tx_clk_pad_n, 
    inout wire        IO_tx_clk_pad_p, 
    inout wire[3:0]   IO_tx_data_pad_n,
    inout wire[3:0]   IO_tx_data_pad_p,

    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n   
);


    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_dpll_ref_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 			S_ae_req; 
	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;
		
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 

	// ---- 显示通路直通(传感器输出 1024x600 = DSI 屏原生分辨率) ----
	wire 			S_crop_tuser;
	wire 			S_crop_tvalid;
	wire [127:0]	S_crop_tdata;
	

    wire        S_ddr_clk;
    wire        S_dsi_tx_clk;

 
    reg[31:0]   S_delay_cnt;
    wire        S_lp_config_start;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;

    wire        S_init_calib_complete; 
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    wire        S_mc_app_wdf_rdy;       

    wire        S_vs_vsync; 
    wire        S_vs_hsync; 
    wire        S_vs_de;    
    wire[23:0]  S_vs_data;  
    
    wire        S_32b_vsync; 
    wire        S_32b_hsync; 
    wire        S_32b_de;    
    wire[31:0]  S_32b_data;  

    wire        S_hs_tx_valid; 
    wire[31:0]  S_hs_tx_data;  
    wire        S_hs_tx_last;  
    wire        S_hs_tx_ready; 

    wire        S_lp_config_done;   
    wire        S_mipi_tx_dpll_locked;

    wire        S_lp_tx_p;
    wire        S_lp_tx_n;

    wire        S_vdieo_rd_en;  
    wire[23:0]  S_video_rd_data;

    wire        S_mixer_vsync;
    wire        S_mixer_hsync;
    wire        S_mixer_de;
    wire[23:0]  S_mixer_data;

    // ---- CAM CHECK: 摄像头链路体检统计快照(详见 04_cam_check/INTEGRATE.md) ----
    wire        S_snap_valid;
    wire [31:0] S_snap_frames, S_snap_pix, S_snap_nonzero;
    wire [39:0] S_snap_sum;

    // ISP 观测口统计(DIAG: 挂 demosaic 输出 128bit 拍, 分诊每帧拍数)
    wire        S_isp_snap_valid;
    wire [31:0] S_isp_snap_frames, S_isp_snap_pix, S_isp_snap_nonzero;
    wire [39:0] S_isp_snap_sum;

    // ---- CAM CHECK/NET: 以太网调试通路内部信号 ----
    wire [95:0] S_awb_tdata;            // ISP AWB 后 96bit 像素观测口
    wire        S_awb_tuser;
    wire        S_awb_tvalid;
    wire        S_gmii_125m;            // GMII/RGMII 125M 时钟(独立 PLL)
    wire        S_gmii_lock;
    wire        S_net_pix_valid;        // (诊断) AWB 观测口有效, bit2/3 旗标用
    wire [23:0] S_net_pix_rgb;
    assign S_net_pix_valid = S_awb_tvalid;
    assign S_net_pix_rgb   = S_awb_tdata[23:0];
    wire        S_mdio_o, S_mdio_oe;    // MDIO 三态

    // 网口诊断旗标(粘滞,置 1 不清):经心跳包显示在电脑端状态页
    // bit0=相机I2C配置完成 bit1=AWB观测口有数据 bit2=转换器在发像素 bit3=像素非全零
    reg [15:0] r_net_diag;
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n)
            r_net_diag <= 16'd0;
        else begin
            if (S_cam_cfg_done)  r_net_diag[0] <= 1'b1;
            if (S_awb_tvalid)    r_net_diag[1] <= 1'b1;
            if (S_net_pix_valid) r_net_diag[2] <= 1'b1;
            if (S_net_pix_valid && (S_net_pix_rgb != 24'd0))
                r_net_diag[3] <= 1'b1;
            if (w_fb_lt)         r_net_diag[4] <= 1'b1;   // v11g: 帧拍数曾 <153600
            if (w_fb_gt)         r_net_diag[5] <= 1'b1;   // v11g: 帧拍数曾 >153600
        end
    end


    assign O_screen_pwm = 1'b1;


    always @(posedge S_10m_clk or negedge S_mipi_tx_dpll_locked) begin
        if(!S_mipi_tx_dpll_locked)
            S_delay_cnt <= 'd0;
        else
            if(S_delay_cnt >= 'd10000000)
                S_delay_cnt <= S_delay_cnt;
            else
                S_delay_cnt <= S_delay_cnt + 'd1;
    end

    assign S_lp_config_start = S_delay_cnt >= 'd200 ? 1'b1 : 1'b0;
	
	
    assign S_rst_n 		= S_pll_lock;
	
	assign O_cam_rst 	= 1'b1;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),
        .clk2_out    ( S_dpll_ref_clk    ),
		.clk3_out    ( S_10m_clk         ),

        .lock        ( S_pll_lock        )

    );
	

  
  ae_set u_ae_set (
      .I_clk(S_24m_clk),
      .I_rst(~S_rst_n),
      .I_btn({I_button,2'b11}),
      .I_cam_cfg_done(S_cam_cfg_done),
      .I_ae_cfg_done(S_ae_cfg_done),
      .O_ae_req(S_ae_req),
      .O_ae(S_ae),
      .O_ag(S_ag)
  );
  
    uicfgcs500 #(
      .CLK_DIV(24000000 / 100000 - 1)
  ) u_uicfgcs500 (
      .I_clk(S_24m_clk),  //系统时钟输入
      .I_rst_n(S_rst_n),  //系统复位输入
      .I_ae_req(S_ae_req),
      .I_ae(S_ae),
      .I_ag(S_ag),
      .O_cam_scl(O_cam_scl),  //I2C总线，SCL时钟
      .IO_cam_sda(IO_cam_sda),  //I2C总线，SDA数据
      .O_cfg_done(S_cam_cfg_done),  //摄像头寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done)  //AE配置完成
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "0dB"   ),//"0dB","1.5dB","3dB","4.5dB","6dB","7.5dB","9dB","10.5dB"
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(1024),
.IMG_HEIGHT(600),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// v11f: line_retimer 替换 image_correction —— 上游行切分实测不稳定(行长
// 255~256 抖动, 心跳监视器读数), 其 H_valid 窗口/间隙检测与上游 tlast 相互
// 作用产生行错位; 本模块按帧内 valid 序号强制重切(256拍x600行), 免疫抖动。
line_retimer #(
    .BEATS_PER_LINE ( 256 ),
    .LINES          ( 600 )
) u_line_retimer (
    .I_clk    ( S_csi_rx_clk  ),
    .I_rst_n  ( S_rst_n       ),

    .I_tuser  ( S_axis_tuser  ),
    .I_tvalid ( S_axis_tvalid ),
    .I_tdata  ( S_axis_tdata  ),

    .O_tuser  ( S_raw_tuser  ),
    .O_tvalid ( S_raw_tvalid ),
    .O_tlast  ( S_raw_tlast  ),
    .O_tdata  ( S_raw_tdata  )
);


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


// v13: 自研 ISP(cvp_proc 齿轮箱+DPC+demosaic → cvp_awb → pack_4)替换米联客 isp_top
// (米联客 demosaic 的 zhenghe 行重整机制存在逐行相位滑移, 图像每行错 4 像素;
//  cvp 系列为确定性流水, 带自检, 接口: 40bit RAW10 组进 -> 96bit RGB 组出)
wire        S_isp_pix_valid;
wire [23:0] S_isp_pix_rgb;
wire        S_isp_pix_fs;

cvp_proc #(
    .IMG_W  ( 1024 ),
    .IMG_H  (  600 )
) u_cvp_proc (
    .i_clk              ( S_csi_rx_clk ),
    .i_rst_n            ( S_rst_n      ),
    .i_mode             ( 3'd0         ),   // 0=彩色直通(像素级算法不用)

    .i_grp_valid        ( S_raw_tvalid ),
    .i_grp_data         ( S_raw_tdata  ),
    .i_grp_frame_start  ( S_raw_tuser  ),
    .i_grp_line_last    ( S_raw_tlast  ),

    .o_pix_valid        ( S_isp_pix_valid ),
    .o_pix_rgb          ( S_isp_pix_rgb   ),
    .o_pix_frame_start  ( S_isp_pix_fs    ),
    .o_pix_line_last    (                  ),

    .o_ae_eq_q8         (                  ),   // AE 沿用板上 ae_set 机制
    .o_ae_update        (                  ),
    .o_ae_req           (                  ),
    .o_ae_exp           (                  ),
    .o_ae_gain          (                  ),
    .o_ae_locked        (                  )
);

wire        S_awb1_valid;
wire        S_awb1_fs;
wire [23:0] S_awb1_rgb;

cvp_awb #(
    .IMG_W  ( 1024 ),
    .IMG_H  (  600 )
) u_cvp_awb (
    .i_clk          ( S_csi_rx_clk    ),
    .i_rst_n        ( S_rst_n         ),
    .i_valid        ( S_isp_pix_valid ),
    .i_rgb          ( S_isp_pix_rgb   ),
    .i_frame_start  ( S_isp_pix_fs    ),
    .o_valid        ( S_awb1_valid    ),
    .o_rgb          ( S_awb1_rgb      ),
    .o_frame_start  ( S_awb1_fs       )
);

// 1像素/拍 -> 96bit 组(4像素), 驱动网口观测口语义信号 S_awb_*
pack_4 u_pack4 (
    .I_clk         ( S_csi_rx_clk ),
    .I_rst_n       ( S_rst_n      ),
    .I_valid       ( S_awb1_valid ),
    .I_rgb         ( S_awb1_rgb   ),
    .I_frame_start ( S_awb1_fs    ),
    .O_tvalid      ( S_awb_tvalid ),
    .O_tdata       ( S_awb_tdata  ),
    .O_tuser       ( S_awb_tuser  )
);

// DSI/DDR 主通路: 96bit -> 128bit(原 isp_top 内部转换, 顶层直接例化)
data_96bit_to_128bit u_data_96bit_to_128bit(
    .I_clk              ( S_csi_rx_clk  ),
    .I_rst_n            ( S_rst_n       ),
    .I_96b_frame_start  ( S_awb_tuser   ),
    .I_96b_valid        ( S_awb_tvalid  ),
    .I_96b_data         ( S_awb_tdata   ),
    .O_128b_frame_start ( S_ISP_O_tuser ),
    .O_128b_valid       ( S_ISP_O_tvalid),
    .O_128b_data        ( S_ISP_O_tdata )
);


    // 传感器输出 1024x600 = DSI 屏原生分辨率, 裁剪模块为参数化直通(IN==OUT);
    // 网口走下面的 O_awb 全幅观测口, 不经过本模块
    rgb_frame_crop #(
        .IN_W  ( 1024 ),
        .IN_H  (  600 ),
        .OUT_W ( 1024 ),
        .OUT_H (  600 )
    ) u_rgb_frame_crop (
        .I_clk    ( S_csi_rx_clk ),
        .I_rst_n  ( S_rst_n      ),

        .I_tuser  ( S_ISP_O_tuser  ),
        .I_tvalid ( S_ISP_O_tvalid ),
        .I_tdata  ( S_ISP_O_tdata  ),

        .O_tuser  ( S_crop_tuser  ),
        .O_tvalid ( S_crop_tvalid ),
        .O_tdata  ( S_crop_tdata  )
    );


    video_in u_video_in(
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        .I_camera_frame_start ( S_crop_tuser  ),
        .I_camera_valid       ( S_crop_tvalid ),
        .I_camera_data        ( S_crop_tdata  ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy   ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready      )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 'd0;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_data;


    video_out u_video_out(
        .I_rst_n             ( S_rst_n              ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready     ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_dsi_tx_clk         ),
        .I_video_vsync       ( S_vs_vsync           ),
        .I_video_rd_en       ( S_vdieo_rd_en        ),
        .O_vdieo_data        ( S_video_rd_data      )
    );



    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             ( S_mc_app_en             ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_cmd            ( S_mc_app_cmd            ),
        .I_mc_app_rdy            ( S_mc_app_rdy            ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren       ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy        ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );



    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_app_cmd           ( S_mc_app_cmd           ),
        .I_mc_app_en            ( S_mc_app_en            ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    video_source #(
        .HTOTAL ( 1344  ),
        .HSA    ( 24    ),
        .HBP    ( 136   ),
        .HFP    ( 160   ),
 
        .VTOTAL ( 635 ),
        .VSA    ( 2    ),
        .VBP    ( 21   ),
        .VFP    ( 12   )
    )u_video_source(
        .I_clk          ( S_dsi_tx_clk     ),
        .I_rst          ( ~S_rst_n         ),

        .I_config_done  ( S_lp_config_done ),

        .O_rgb24b_vsync ( S_vs_vsync       ),
        .O_rgb24b_hsync ( S_vs_hsync       ),
        .O_rgb24b_de    ( S_vs_de          ),
        .O_rgb24b_data  ( S_vs_data        )
    );


    mixer u_mixer(
        .I_clk           ( S_dsi_tx_clk    ),

        .I_video_vsync   ( S_vs_vsync      ),
        .I_video_hsync   ( S_vs_hsync      ),
        .I_video_de      ( S_vs_de         ),

        .O_vdieo_rd_en   ( S_vdieo_rd_en   ),
        .I_video_rd_data ( S_video_rd_data ),

        .O_mixer_vsync   ( S_mixer_vsync   ),
        .O_mixer_hsync   ( S_mixer_hsync   ),
        .O_mixer_de      ( S_mixer_de      ),
        .O_mixer_data    ( S_mixer_data    )
    );



    rgb_24b_to_32b #(
       .H_ACTIVE (1024)
    )u_rgb_24b_to_32b(
        .I_clk   ( S_dsi_tx_clk      ),
        .I_rst   ( ~S_rst_n          ),

        .I_vsync ( S_mixer_vsync     ),
        .I_hsync ( S_mixer_hsync     ),
        .I_de    ( S_mixer_de        ),
        .I_data  ( S_mixer_data      ),
                                               
        .O_vsync ( S_32b_vsync       ),
        .O_hsync ( S_32b_hsync       ),
        .O_de    ( S_32b_de          ),
        .O_data  ( S_32b_data        )
    );


    dsi_video_mode_packet #(
       .H_ACTIVE (1024)
    ) u_dsi_video_mode_packet(
        .I_clk     ( S_dsi_tx_clk  ),
        .I_rst     ( ~S_rst_n      ),
    
        .I_vsync   ( S_32b_vsync   ),
        .I_hsync   ( S_32b_hsync   ),
        .I_de      ( S_32b_de      ),
        .I_data    ( S_32b_data    ),
            
        .O_hs_en   ( S_hs_tx_valid ),
        .O_hs_data ( S_hs_tx_data  ),
        .O_hs_last ( S_hs_tx_last  )
    );



    display_config_wrapper u_display_config_wrapper(
        .I_clk          ( S_10m_clk         ),
        .I_rst          ( ~S_rst_n          ),

        .I_config_start ( S_lp_config_start ),
        .O_config_done  ( S_lp_config_done  ),

        .O_lp_tx_p      ( S_lp_tx_p         ),
        .O_lp_tx_n      ( S_lp_tx_n         )
    );


    mipi_dphy_tx_over_ph1p_mipiio_wrapper#(
        .DPHY_TX_LOCATION        ( "DPHY1"    ),
        .BYTE_NUM                ( 1          ),
        .LANE_NUM                ( 4          ),

        .CLK_LANE_MODE           ( "CONTINUE" ),
        .HS_OUTPUT_VOD           ( "200mV"    ),//"175mV","187.5mV","200mV","212.5mV","225mV","237.5mV","250mV","450mV"
        .HS_OUTPUT_IMPEDANCE     ( "50ohm"    ),//"70ohm","64ohm","58ohm","54ohm","50ohm","47ohm","44ohm","41ohm"
        .HS_OUTPUT_DE_EMPHASIS   ( "0dB"      ),//"0dB","1dB","2dB","3dB","4dB","5dB","6dB"

        .CK_OUTPUT_DELAY         ( 0  ),
        .L0_OUTPUT_DELAY         ( 0  ),
        .L1_OUTPUT_DELAY         ( 0  ),
        .L2_OUTPUT_DELAY         ( 0  ),
        .L3_OUTPUT_DELAY         ( 0  ),

        .DPLL_MULTI_RATIO        ( 20 ), //vco = 100*(20+1)=2100MHz, linerate = 1.05Gbps
        .DPLL_DIV_RATIO          ( 1  ),

        .T_DATA_LPX              ( 10 ),
        .T_DATA_HS_PREPARE       ( 10 ),
        .T_DATA_HS_ZERO          ( 20 ),
        .T_DATA_HS_TRAIL         ( 10 ),
        .T_CLK_LPX               ( 10 ),
        .T_CLK_PREPARE           ( 10 ),
        .T_CLK_ZERO              ( 10 ),
        .T_CLK_PRE               ( 10 ),
        .T_CLK_POST              ( 10 ),
        .T_CLK_TRAIL             ( 10 )
    )u_mipi_dphy_tx_over_ph1p_mipiio_wrapper(
        .I_dphy_pll_ref_clk ( S_dpll_ref_clk        ),
        .I_rst              ( ~S_rst_n              ),
        .O_dpll_locked      ( S_mipi_tx_dpll_locked ),

        .O_hs_tx_clk        ( S_dsi_tx_clk          ),
        .I_hs_tx_valid      ( S_hs_tx_valid         ),
        .I_hs_tx_data       ( S_hs_tx_data          ),
        .I_hs_tx_last       ( S_hs_tx_last          ),
        .O_hs_tx_ready      ( S_hs_tx_ready         ),

        .I_lp_tx_p          ( S_lp_tx_p             ),
        .I_lp_tx_n          ( S_lp_tx_n             ),
   
        .I_lp_rx_en         ( 1'b0                  ),
        .O_lp_rx_p          (                       ),
        .O_lp_rx_n          (                       ),
    
        .IO_tx_clk_pad_n    ( IO_tx_clk_pad_n       ),
        .IO_tx_clk_pad_p    ( IO_tx_clk_pad_p       ),
        .IO_tx_data_pad_n   ( IO_tx_data_pad_n      ),
        .IO_tx_data_pad_p   ( IO_tx_data_pad_p      )
    );


    // ---- CAM CHECK: 摄像头链路体检,每秒从串口打印两行统计(115200-8-N-1) ----
    // 第一行 CAM = RAW10 解包层; 第二行 ISP = AWB 观测口(96bit 拍, 4像素/拍)
    cam_stats #(
        .PIX_W      ( 40           ),
        .LUMA_SHIFT ( 2            ),
        .CLK_SYS_HZ ( 100_000_000  )
    ) u_cam_stats (
        .I_clk_pix ( S_csi_rx_clk       ),
        .I_rst_pix ( ~S_rst_n           ),
        .I_vsync   ( S_raw10_frame_start),
        .I_de      ( S_raw10_valid      ),
        .I_pix     ( S_raw10_data       ),

        .I_clk_sys     ( S_100m_clk     ),
        .I_rst_sys     ( ~S_rst_n       ),
        .O_snap_valid  ( S_snap_valid   ),
        .O_snap_frames ( S_snap_frames  ),
        .O_snap_pix    ( S_snap_pix     ),
        .O_snap_nonzero( S_snap_nonzero ),
        .O_snap_sum    ( S_snap_sum     )
    );

    cam_stats #(
        .PIX_W      ( 96           ),   // v13: cvp ISP 输出(pack_4 后 96bit 组)
        .LUMA_SHIFT ( 16           ),
        .CLK_SYS_HZ ( 100_000_000  )
    ) u_cam_stats_isp (
        .I_clk_pix ( S_csi_rx_clk       ),
        .I_rst_pix ( ~S_rst_n           ),
        .I_vsync   ( S_awb_tuser        ),
        .I_de      ( S_awb_tvalid       ),
        .I_pix     ( S_awb_tdata        ),

        .I_clk_sys     ( S_100m_clk     ),
        .I_rst_sys     ( ~S_rst_n       ),
        .O_snap_valid  ( S_isp_snap_valid   ),
        .O_snap_frames ( S_isp_snap_frames  ),
        .O_snap_pix    ( S_isp_snap_pix     ),
        .O_snap_nonzero( S_isp_snap_nonzero ),
        .O_snap_sum    ( S_isp_snap_sum     )
    );

    cam_report_uart #(
        .CLK_HZ ( 100_000_000 ),
        .BAUD   ( 115200      )
    ) u_cam_report (
        .I_clk         ( S_100m_clk     ),
        .I_rst_n       ( S_rst_n        ),
        .I_snap_valid  ( S_snap_valid   ),
        .I_snap_frames ( S_snap_frames  ),
        .I_snap_pix    ( S_snap_pix     ),
        .I_snap_nonzero( S_snap_nonzero ),
        .I_snap_sum    ( S_snap_sum     ),
        .I_isp_valid   ( S_isp_snap_valid   ),
        .I_isp_frames  ( S_isp_snap_frames  ),
        .I_isp_pix     ( S_isp_snap_pix     ),
        .I_isp_nonzero ( S_isp_snap_nonzero ),
        .I_isp_sum     ( S_isp_snap_sum     ),
        .O_uart_tx     ( O_uart_tx      )
    );


    // ---- CAM CHECK/NET: 以太网调试通路(把 ISP 后像素流经 ETHA 网口 UDP 发给电脑) ----
    // 125M GMII 时钟(独立 PLL, 25M 输入; PLL IP 拷贝自 rgmii 例程)
    pll_gmii125 u_pll_gmii125 (
        .refclk    ( I_sys_clk    ),
        .pllreset  ( ~I_rst_n     ),
        .clk0_out  ( S_gmii_125m  ),
        .clk1_out  (              ),
        .clk2_out  (              ),
        .lock      ( S_gmii_lock  )
    );

    // ---- DIAG: 行长监视(uial2axis 输出层), 经心跳包 scan word 上报 ----
    // 每帧统计行长(拍)的 min/max, 编码为 (值-248) 的 4bit(248..263, F=饱和),
    // scan_word = {8'b0, min_d, max_d}。行长应恒 256(=0x88 编码: 256-248=8)。
    reg [8:0] r_line_beats, r_line_min, r_line_max;
    wire [8:0] w_min_dev = r_line_min - 9'd248;
    wire [8:0] w_max_dev = r_line_max - 9'd248;
    wire [3:0] w_min_d = (r_line_min >= 9'd248 && r_line_min <= 9'd263) ? w_min_dev[3:0] : 4'hF;
    wire [3:0] w_max_d = (r_line_max >= 9'd248 && r_line_max <= 9'd263) ? w_max_dev[3:0] : 4'hF;

    // v11i: 监视 raw10 解包层(S_raw10_valid)的连续 valid 段长(段=行, 不依赖 tlast)。
    // uial2axis 层行长/帧拍数已证恒定, 但图像内容逐行滑 1 拍 => 杂散拍在更上游。
    // scan 编码: [11:8]=min偏差(248基), [3:0]=max偏差。
    reg [31:0] r_frame_beats;   // 帧内总拍数(tuser 间隔), 借 flags 观测
    reg        r_rl_v_d;        // 上一拍 valid(段边界检测)
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin
            r_line_beats <= 9'd0;
            r_line_min   <= 9'd511;
            r_line_max   <= 9'd0;
            r_frame_beats<= 32'd0;
            r_rl_v_d     <= 1'b0;
        end else begin
            r_rl_v_d <= S_raw10_valid;
            if (S_raw10_frame_start) r_frame_beats <= 32'd1;
            else if (S_raw10_valid) r_frame_beats <= r_frame_beats + 32'd1;

            if (S_raw10_valid) begin
                if (!r_rl_v_d) begin
                    // 段首: 结算上一段(如果够长, 排除杂散短段)
                    if (r_line_beats >= 9'd100) begin
                        if (r_line_beats < r_line_min) r_line_min <= r_line_beats;
                        if (r_line_beats > r_line_max) r_line_max <= r_line_beats;
                    end
                    r_line_beats <= 9'd1;
                end else begin
                    r_line_beats <= r_line_beats + 9'd1;
                end
            end
        end
    end
    reg [7:0] r_last_fb;      // 上帧拍数 mod 256(tuser 拍锁存)
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n)
            r_last_fb <= 8'h00;
        else if (S_axis_tuser)
            r_last_fb <= r_frame_beats[7:0];   // 新帧首锁存上一帧的计数
    end

    // 帧拍数偏差标志(期望153600): bit4=曾<153600, bit5=曾>153600
    wire w_fb_lt = (r_frame_beats > 32'd1000) && (r_frame_beats < 32'd153600);
    wire w_fb_gt = (r_frame_beats > 32'd153600) && (r_frame_beats < 32'd200000);

    // v10: cvp_rgb_stream_pack 已移除(其 FIFO 读协议在 40.2MHz 像素域无法
    // 实时展开, 见 v5/v7/v8 历史) —— AWB 观测口 96bit 拍(4像素/拍)直连网口
    // 模块, 字节展开在 GMII 125M 域完成; tuser 帧标记带内随数据流跨域。

    // 以太网视频调试通路(网络模块; UDP: 192.168.1.66 -> 192.168.1.100, 端口 6000,
    // 1024x600 每帧都发 ≈20fps, 1280包/帧, 约310Mbps; 电脑端: eth_video_rx.py --width 1024 --height 600)
    cvp_eth_dbg #(
        .IMG_W       ( 1024      ),
        .IMG_H       ( 600       ),
        .FRAME_SKIP  ( 1         ),
        .DATA_BYTES  ( 1440      ),
        .GEN_TESTPAT ( 0         ),   // 0=相机流(彩条分诊已于 v11b 验证通路正确)
        .PHY_ADDR    ( 5'd1      )
    ) u_eth_dbg (
        .i_clk_pix      ( S_csi_rx_clk      ),
        .i_rst_pix_n    ( S_rst_n           ),
        .i_valid        ( S_awb_tvalid      ),
        .i_rgb          ( S_awb_tdata       ),
        .i_tuser        ( S_awb_tuser       ),
        .i_clk_100m     ( S_100m_clk        ),
        .i_rst_100m_n   ( S_rst_n           ),
        .i_clk_gmii     ( S_gmii_125m       ),
        .i_rst_gmii_n   ( S_gmii_lock       ),
        .i_txd_swap     ( 1'b0              ),
        .i_dbg_flags    ( r_net_diag        ),
        .i_scan_word    ( {8'b0, w_min_d, w_max_d} ),  // DIAG: raw10 层段长(行) min/max 偏差(248基)
        .o_scan_rotate  (                   ),
        .o_rgmii_txd    ( O_eth_rgmii_txd   ),
        .o_rgmii_tx_ctl ( O_eth_rgmii_tx_ctl),
        .o_rgmii_txc    ( O_eth_rgmii_txc   ),
        .o_eth_mdc      ( O_eth_mdc         ),
        .o_eth_mdio_o   ( S_mdio_o          ),
        .o_eth_mdio_oe  ( S_mdio_oe         ),
        .i_eth_mdio_i   ( S_mdio_i          ),
        .o_link         (                   ),
        .o_act          (                   ),
        .o_ext_dly      (                   )
    );

    // MDIO 三态 + PHY 复位(PHY 上电自复位, 恒 1)
    assign O_eth_rst_n = 1'b1;
    assign IO_eth_mdio = S_mdio_oe ? S_mdio_o : 1'bz;
    assign S_mdio_i    = IO_eth_mdio;

endmodule