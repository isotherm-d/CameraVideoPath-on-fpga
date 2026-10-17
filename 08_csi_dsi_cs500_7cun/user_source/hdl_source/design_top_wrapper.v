

module design_top_wrapper (
    input wire        I_sys_clk,
    input wire        I_sw1_box,   /* SW1(R10,低有效)：识别框开关。原 I_rst_n 复位键已写死
                                    * （按一下 PLL 重锁->S_pll_lock 掉->全系统复位->死机，
                                    *   队长 2026-10-17 指令"不许复位"），引脚改作开关 */
      
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
    input  wire [3:0] I_eth_rgmii_rxd,   // v20: 接收方向(命令通路)
    input  wire       I_eth_rgmii_rx_ctl,
    input  wire       I_eth_rgmii_rx_clk,
    output wire       O_eth_mdc,
    inout  wire       IO_eth_mdio,
    output wire       O_eth_rst_n,

    // ---- CAM CHECK/NET: ETHB 网口(镜像 ETHA 发送方向, 接副板做 HDMI 输出) ----
    // 仅 TX 镜像, 无接收/命令通路; ETHB_MDIO(R5) 不接(副板无需 MDIO 管理)
    output wire [3:0] O_ethb_rgmii_txd,
    output wire       O_ethb_rgmii_tx_ctl,
    output wire       O_ethb_rgmii_txc,
    output wire       O_ethb_mdc,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p


);


    wire        	S_100m_clk;
    wire        	S_24m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 		S_ae_req;

    // v20: 网络命令接收(RXCK 域解析, 100M 域寄存器输出)
    wire v2_valid,legacy_valid;wire [15:0] v2_req,v2_cfg;wire [7:0] v2_op,v2_addr,legacy_cmd;
    wire [31:0] v2_value;wire [23:0] legacy_value;
    wire cfg_error,iic_error;wire adv_valid,adv_sof,adv_eof;
    wire [23:0] adv_rgb;wire [31:0] adv_frame_id,pack_frame_id;
    wire [1535:0] adv_status;wire [127:0] sensor_diagnostics;wire adv_status_valid,adv_status_ready;
    wire net_overflow,net_tx_done;wire [31:0] net_tx_fid;
    wire [1:0]  S_cmd_mode;
    wire [15:0] S_cmd_ae;
    wire        S_cmd_ae_wr;   // v23: 曝光命令单拍(通知 cvp_proc 重写传感器)
    wire [8:0]  S_cmd_gr, S_cmd_gg, S_cmd_gb;
    wire        S_cmd_swap;
    wire        S_cmd_awb_en;   // v21: 0=冻结 AWB(手动白平衡) 1=自动
    wire [6:0]  S_cmd_kelvin;   // v21: 色温, 单位 100K
	
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


    // 方案C(2026-10-11): UART 诊断链(双 cam_stats + cam_report_uart, 原 206-212 行快照线
    // 与 819-878 行三个实例)已移除, 省 ~1337 FF; 链路诊断由 eth_dbg 的 UDP 状态包覆盖。
    // O_uart_tx 保持常高(UART 空闲电平), 顶层端口与 .adc 引脚约束不变。

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
    always @(posedge S_100m_clk or negedge S_rst_n) begin
        if (!S_rst_n)
            r_net_diag <= 16'd0;
        else begin
            if (S_cam_cfg_done)  r_net_diag[0] <= 1'b1;
            if (S_awb_tvalid)    r_net_diag[1] <= 1'b1;
            if (S_net_pix_valid) r_net_diag[2] <= 1'b1;
            if (S_net_pix_valid && (S_net_pix_rgb != 24'd0))
                r_net_diag[3] <= 1'b1;
        end
    end


    // Network-only build: the local DSI screen and its DDR buffer are removed.
    assign O_screen_pwm = 1'b0; // Keep the backlight off.

    assign S_rst_n 		= S_pll_lock;
	
	assign O_cam_rst 	= 1'b1;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( 1'b0             ),  /* 复位写死（原 ~I_rst_n） */
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),
        .clk2_out    (                   ),
		.clk3_out    (                   ),

        .lock        ( S_pll_lock        )

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
      .O_cfg_error(cfg_error),.O_iic_error(iic_error),.O_diagnostics(sensor_diagnostics),
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
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),   // v22b: 传感器 MIPI 实发 720 行数据(CAM p/f/320=720 精确) —— 727 为采窗行数但含 7 行不输出, tuser 按 727 计数导致每帧漂 7 行(1.7s 漂半帧=上下互换)
                    // 设 720 会使帧头早 7 行 -> 底部行绕到顶部(line_retimer 取错窗口)
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
    .BEATS_PER_LINE ( 320 ),
    .LINES          ( 720 )
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


// v13: 自研 ISP(cvp_proc 齿轮箱+DPC+demosaic → cvp_awb → pack_4)替换米联客 isp_top
// (米联客 demosaic 的 zhenghe 行重整机制存在逐行相位滑移, 图像每行错 4 像素;
//  cvp 系列为确定性流水, 带自检, 接口: 40bit RAW10 组进 -> 96bit RGB 组出)
wire        S_isp_pix_valid;
wire [23:0] S_isp_pix_rgb;
wire        S_isp_pix_fs;

/* V27 startup qualification wires（前移声明：ModelSim 严格模式下
 * "先用于端口连接、后 wire 声明"会撞隐式线网，vlog-2388） */
wire camera_group_valid, camera_group_sof;
/* detect 组接入的 clean 流抽头（声明同样前移，见文件尾部 detect 块） */
wire        w_clean_valid, w_clean_sof, w_clean_eof;
wire [23:0] w_clean_rgb;
wire [31:0] w_clean_frame_id;
wire [11:0] w_clean_x, w_clean_y;           /* pixfill 裁剪寻址用 */

// v13b: 组缓冲吸收 raw10 行突发(齿轮箱 4 拍/组跟不上背靠背突发, 实测丢 5/8)
wire        S_gf_valid, S_gf_tuser, S_gf_tlast;
wire [39:0] S_gf_data;

group_fifo u_group_fifo (
    .I_wr_clk    ( S_csi_rx_clk ),   // 40.2M 写(突发)
    .I_wr_rst_n  ( S_rst_n      ),
    .I_wr_valid  ( S_raw_tvalid ),
    .I_wr_data   ( S_raw_tdata  ),
    .I_wr_tuser  ( S_raw_tuser  ),
    .I_wr_tlast  ( S_raw_tlast  ),
    .I_rd_clk    ( S_100m_clk   ),   // 100M 读(cvp ISP 域)
    .I_rd_rst_n  ( S_rst_n      ),
    .O_rd_valid  ( S_gf_valid   ),
    .O_rd_data   ( S_gf_data    ),
    .O_rd_tuser  ( S_gf_tuser   ),
    .O_rd_tlast  ( S_gf_tlast   )
);

cvp_proc #(
    .IMG_W  ( 1280 ),
    .IMG_H  (  720 ),
    .AE_EXP_CODE (16'd500) // v25 default exposure, synchronized with wb_profile.json.
) u_cvp_proc (
    .i_clk              ( S_100m_clk ),
    .i_rst_n            ( S_rst_n      ),
    .i_mode             ( 3'd0         ),   // 0=彩色直通(像素级算法不用)

    .i_grp_valid        ( camera_group_valid   ),
    .i_grp_data         ( S_gf_data    ),
    .i_grp_frame_start  ( camera_group_sof   ),
    .i_grp_line_last    ( S_gf_tlast   ),

    .o_pix_valid        ( S_isp_pix_valid ),
    .o_pix_rgb          ( S_isp_pix_rgb   ),
    .o_pix_frame_start  ( S_isp_pix_fs    ),
    .o_pix_line_last    (                  ),

    .i_cam_cfg_done     ( S_cam_cfg_done  ),

    /* v23: 网络曝光命令(与 i_clk 同 100M 域, 直连免 CDC) */
    .i_cmd_ae           ( S_cmd_ae        ),
    .i_cmd_ae_wr        ( 1'b0     ),

    .o_ae_req           (         ),
    .o_ae               (             ),
    .o_ag               (            )
);

// V27 startup qualification: wait for initialization, then begin at a real SOF.
// （camera_group_valid/sof 已前移至 cvp_proc 之前声明）
cvp_camera_gate startup_gate(.clk(S_100m_clk),.rst_n(S_rst_n),.i_cfg_done(S_cam_cfg_done),.i_ae_done(S_ae_cfg_done),
 .i_valid(S_gf_valid),.i_sof(S_gf_tuser),.o_valid(camera_group_valid),.o_sof(camera_group_sof));
// V26: shared 30 fps processing core and configuration/status interfaces.
cvp_advanced #(.V27(1)) advanced(
 .clk(S_100m_clk),.rst_n(S_rst_n),.i_capture_valid(camera_group_valid),.i_capture_event(camera_group_sof),.keys_n(I_button),
 .i_valid(S_isp_pix_valid),.i_sof(S_isp_pix_fs),.i_rgb(S_isp_pix_rgb),
 .cmd_valid(v2_valid),.cmd_req(v2_req),.cmd_cfg(v2_cfg),.cmd_op(v2_op),.cmd_addr(v2_addr),.cmd_value(v2_value),
 .legacy_valid(legacy_valid),.legacy_cmd(legacy_cmd),.legacy_value(legacy_value),
 .cfg_clk(S_24m_clk),.i_cam_done(S_cam_cfg_done),.i_ae_done(S_ae_cfg_done),.i_iic_error(iic_error),.i_cfg_error(cfg_error),
 .sensor_req(S_ae_req),.sensor_exp_cfg(S_ae),.sensor_gain_cfg(S_ag),
 .o_valid(adv_valid),.o_sof(adv_sof),.o_eof(adv_eof),.o_rgb(adv_rgb),.o_frame_id(adv_frame_id),
 .i_sensor_diagnostics(sensor_diagnostics),.status_data(adv_status),.status_valid(adv_status_valid),.status_ready(adv_status_ready),
 .i_net_overflow(net_overflow),.i_net_tx_done(net_tx_done),.i_net_tx_fid(net_tx_fid),.net_clk(S_gmii_125m),.net_rst_n(S_gmii_lock),
 .time_ticks(),.result_done_tick(64'd0),
 /* detect 框 → GUI 画框：bridge 描述符直通 result 口，class=0=已检出白细胞 */
 .result_valid(w_res_valid),.result_ready(w_res_ready),.result_frame(w_res_frame),.result_roi(w_res_roi16),.result_class(8'd0),.result_bbox(w_res_bbox),.result_score(32'd100),.result_format(7'd0),
 /* ---- detect 组接入（2026-10-10，详见 detect/README.md）----
  * clean 流（AWB 后、风格化前）→ det_color_feat（HSV 紫窗分类）
  * → det_wbc20（CCL+簇合并 → 逐细胞框 ≤10）→ det_roi_bridge
  * （框 → V26 roi 块流，帧号透传）。分类核未接入前 roi_valid 悬空
  * 于 w_roi_valid（调试可见），result_* 保持安全常量。 */
 .clean_pixel(),.clean_valid(w_clean_valid),.clean_sof(w_clean_sof),.clean_eol(),.clean_eof(w_clean_eof),.clean_rgb(w_clean_rgb),.clean_x(w_clean_x),.clean_y(w_clean_y),.clean_frame_id(w_clean_frame_id),.clean_cfg_id()
);

/* ---------------- detect 白细胞检测链（detect/ 目录，2026-10-10） ---------------- */
/* w_clean_* 已前移声明（cvp_proc 之前）；此处只留例化 */
localparam N_BOX_W = 5;                // 检测框数上限（与 det_wbc20 N_OUT 一致）

wire        w_det_valid, w_det_fs;
wire [2:0]  w_det_cid;
wire        w_cc_valid;                     /* det_color_feat → cid 滤波 → det_wbc20 */
wire [2:0]  w_cc_cid;
wire [N_BOX_W*48-1:0] w_det_box_xy;
wire        w_det_box_tog;
wire        w_roi_valid;                // 调试观测点（ILA/仿真）
wire [63:0] w_roi_bbox;
wire [3:0]  w_roi_rd_sel;
wire [7:0]  w_pixfill_data;
wire        w_pixfill_rst, w_pixfill_inc;
wire [N_BOX_W-1:0] w_pixfill_cap;
wire        w_res_valid;                    /* bridge 描述符 → GUI 画框 */
wire        w_res_ready;
wire [31:0] w_res_frame;
wire [15:0] w_res_roi16;

det_color_feat #(
    .HUE_CB (10'd700),                  // 白细胞紫色窗 246°（宽窗实测最优）
    .HUE_BM (10'd996),                  // 349.5°（ISP 联合仿真重标定，见 docs）
    .HUE_MR (10'd1010),                 // 354.5°（随 BM 同步抬，防 RED 拦截）
    .S_MIN  (8'd100)                    // 饱和度门限（31 张全量回归冻结参数）
) u_det_color (
    .i_clk         (S_100m_clk),
    .i_rst_n       (S_rst_n),
    .i_valid       (adv_valid),          /* C-2：改接显示流（clean 抽头板上实测无数据） */
    .i_rgb         (adv_rgb),
    .i_frame_start (adv_sof),
    .o_valid       (w_cc_valid),
    .o_frame_start (w_det_fs),
    .o_hue         (),
    .o_sat         (),
    .o_val         (),
    .o_cid         (w_cc_cid)
);

/* 3x3 多数表决：杀 S_MIN=100 细碎噪点的孤立紫像素（真实帧联仿产物，
 * 标签预算治理——见 detect/README.md 与 tb_det_newlink 诊断记录） */
det_cid_filter #(
    .IMG_W (1280),
    .WBC_CID (3'd5)
) u_cid_filter (
    .i_clk       (S_100m_clk),
    .i_rst_n     (S_rst_n),
    .i_valid     (w_cc_valid),
    .i_cid       (w_cc_cid),
    .o_valid     (w_det_valid),
    .o_cid       (w_det_cid)
);

/* 开运算（3x3）：9979dd7 只入了模块文件与 TB，wrapper 从未例化
 * （板上链=未经 open3 的链，与仿真验证链不一致，本提交修正） */
wire        w_open_valid, w_open_bin;
det_bin_open3 #(
    .IMG_W (1280)
) u_open3 (
    .i_clk       (S_100m_clk),
    .i_rst_n     (S_rst_n),
    .i_valid     (w_det_valid),
    .i_bin       (w_det_cid == 3'd5),
    .o_valid     (w_det_open_valid),
    .o_bin       (w_open_bin)
);
wire [2:0] w_det_cid_open = (w_det_open_valid && w_open_bin) ? 3'd5 : 3'd0;

det_wbc20 #(
    .IMG_W (1280), .IMG_H (720),
    .WBC_CID (3'd5),
    .MIN_AREA (12'd400),
    .N_OUT (N_BOX_W),
    .COORD_ADJ (12'd0),
    .ENABLE_FOV (1'b0),                 // 实时相机全画幅（拍屏图才需 FOV 掩膜）
    .COMPACT_PCT (37),
    .MAX_AREA_PCT (15),
    .MERGE_GAP (12'd2),
    .SEED_MIN (256),
    .MERGE_MAXWH (128)
) u_det_wbc (
    .i_clk        (S_100m_clk),
    .i_rst_n      (S_rst_n),
    .i_valid      (w_det_open_valid),
    .i_cid        (w_det_cid_open),
    .o_box_xy     (w_det_box_xy),
    .o_box_text   (),
    .o_box_color  (),
    .o_frame_done (),
    .o_box_toggle (w_det_box_tog)
);


det_roi_bridge #(
    .N_BOX (N_BOX_W),
    .BLK_BYTES (1024)
) u_det_roi (
    .i_clk        (S_100m_clk),
    .i_rst_n      (S_rst_n),
    .i_box_xy     (w_det_box_xy),
    .i_box_toggle (w_det_box_tog),
    .i_frame_id   (w_clean_frame_id),
    .i_pix_en     (1'b1),               // pixfill 供真实灰度（2026-10-10 起）
    .i_pix_data   (w_pixfill_data),
    .o_pix_req    (w_pixfill_inc),
    .i_captured   (w_pixfill_cap),     // TEST bisect: 强制 captured=1 屏蔽 pixfill 门控
    .o_blk_start  (w_pixfill_rst),
    .o_valid      (w_roi_valid),
    .i_ready      (1'b1),               // patch_bridge 侧恒收（分类未接，块内容弃）
    .o_data       (),
    .o_sop        (),
    .o_eop        (),
    .o_frame_id   (),
    .o_roi_id     (w_roi_rd_sel),
    .o_cfg_id     (),
    .o_bbox       (w_roi_bbox),
    .o_width      (),
    .o_height     (),
    .o_channels   (),
    .o_format     (),
    /* 结果描述符 → GUI 画框（检测阶段 class=0 = "已检出白细胞"） */
    .o_desc_valid (w_res_valid),
    .i_desc_ready (w_res_ready),
    .o_desc_frame (w_res_frame),
    .o_desc_roi   (w_res_roi16),
    .o_desc_bbox  (w_res_bbox)
);

/* ROI 像素填充：clean 流过时按框快照裁 32x32 灰度小图到每框 1KB 缓存，
 * 供 bridge 块发送真实像素（分类核的输入图）。 */
u_roi_pixfill #(
    .N_BOX (N_BOX_W),
    .IMG_W (1280),
    .IMG_H (720)
) u_roi_fill (
    .i_clk        (S_100m_clk),
    .i_rst_n      (S_rst_n),
    .i_pix_valid  (w_clean_valid),
    .i_pix_x      (w_clean_x),
    .i_pix_y      (w_clean_y),
    .i_pix_rgb    (w_clean_rgb),
    .i_box_xy     (w_det_box_xy),
    .i_box_toggle (w_det_box_tog),
    .o_captured   (w_pixfill_cap),
    .i_rd_sel     (w_roi_rd_sel[3:0]),
    .o_rd_data    (w_pixfill_data),
    .i_rd_rst     (w_pixfill_rst),
    .i_rd_inc     (w_pixfill_inc)
);
// 1像素/拍 -> 96bit 组(4像素), 驱动网口观测口语义信号 S_awb_*
/* ---- C-2：检测框视频叠加（框烤进像素，GUI/DSI/副板 HDMI 免计算可见）----
 * 常量测试框 (100,100)-(300,250) 常开=叠加通路自检；检测框 det_wbc20 直驱。 */
wire [23:0] w_ovl_rgb;
wire        w_ovl_valid, w_ovl_sof;
cvp_box_overlay #(
    .N_BOX (N_BOX_W),
    .IMG_W (1280),
    .IMG_H (720)
) u_box_overlay (
    .i_clk        ( S_100m_clk   ),
    .i_rst_n      ( S_rst_n      ),
    .i_valid      ( adv_valid    ),
    .i_sof        ( adv_sof      ),
    .i_rgb        ( adv_rgb      ),
    .o_valid      ( w_ovl_valid  ),
    .o_sof        ( w_ovl_sof    ),
    .o_rgb        ( w_ovl_rgb    ),
    .i_box_xy     ( w_det_box_xy ),
    .i_box_toggle ( w_det_box_tog),
    .i_test_box   ( {12'd0, 12'd0, 12'd1279, 12'd719} ),
    .i_test_en    ( 1'b0         ),   /* DIAG 完成：自检框关闭 */
    /* 诊断：原始分类标记（白点 = det_color_feat 判定为紫的像素） */
    .i_mark_valid ( w_cc_valid ),
    .i_mark_cid   ( w_cc_cid   ),
    .i_mark_en    ( 1'b0           ),   /* 诊断标记关闭（交付态） */
    .i_sw1_n      ( I_sw1_box      )    /* SW1：识别框开关（overlay 内部防抖翻转） */
);

pack_4 u_pack4 (
    .I_frame_id(adv_frame_id),.O_frame_id(pack_frame_id),
    .I_clk         ( S_100m_clk   ),
    .I_rst_n       ( S_rst_n      ),
    .I_valid       ( w_ovl_valid  ),
    .I_rgb         ( w_ovl_rgb    ),
    .I_frame_start ( w_ovl_sof    ),
    .O_tvalid      ( S_awb_tvalid ),
    .O_tdata       ( S_awb_tdata  ),
    .O_tuser       ( S_awb_tuser  )
);

// The packed RGB stream feeds Ethernet directly; no DDR/DSI dependency.

    // ---- 方案C: 原 CAM CHECK 三个实例(u_cam_stats/u_cam_stats_isp/u_cam_report)已移除 ----
    assign O_uart_tx = 1'b1;   // UART 空闲电平, 引脚约束保持不变


    // ---- CAM CHECK/NET: 以太网调试通路(把 ISP 后像素流经 ETHA 网口 UDP 发给电脑) ----
    // 125M GMII 时钟(独立 PLL, 25M 输入; PLL IP 拷贝自 rgmii 例程)
    pll_gmii125 u_pll_gmii125 (
        .refclk    ( I_sys_clk    ),
        .pllreset  ( 1'b0         ),   /* 复位写死（原 ~I_rst_n） */
        .clk0_out  ( S_gmii_125m  ),
        .clk1_out  (              ),
        .clk2_out  (              ),
        .lock      ( S_gmii_lock  )
    );

    // v20: 网络命令接收器(RGMII RX -> 曝光/白平衡命令寄存器)
    cvp_cmd_rx u_cmd_rx (
        .I_rxclk       ( I_eth_rgmii_rx_clk ),
        .I_rst_n_rx    ( S_gmii_lock        ),   // RXCK 域复位(PLL 锁定后)
        .I_rxd         ( I_eth_rgmii_rxd    ),
        .I_rxctl       ( I_eth_rgmii_rx_ctl ),
        .I_rst_n_gmii  ( S_rst_n            ),
        .I_clk_gmii    ( S_gmii_125m        ),
        .I_clk100      ( S_100m_clk         ),
        .I_rst_n_100   ( S_rst_n            ),
        .o_v2_valid(v2_valid),.o_req_id(v2_req),.o_cfg_id(v2_cfg),.o_op(v2_op),.o_addr(v2_addr),.o_value(v2_value),
        .o_legacy_valid(legacy_valid),.o_legacy_cmd(legacy_cmd),.o_legacy_value(legacy_value),
        .o_mode        ( S_cmd_mode         ),
        .o_net_ae      ( S_cmd_ae           ),
        .o_gain_r      ( S_cmd_gr           ),
        .o_gain_g      ( S_cmd_gg           ),
        .o_gain_b      ( S_cmd_gb           ),
        .o_swap        ( S_cmd_swap         ),
        .o_awb_en      ( S_cmd_awb_en       ),
        .o_kelvin      ( S_cmd_kelvin       ),
        .o_exp_wr      ( S_cmd_ae_wr        )
    );

    // v10: cvp_rgb_stream_pack 已移除(其 FIFO 读协议在 40.2MHz 像素域无法
    // 实时展开, 见 v5/v7/v8 历史) —— AWB 观测口 96bit 拍(4像素/拍)直连网口
    // 模块, 字节展开在 GMII 125M 域完成; tuser 帧标记带内随数据流跨域。

    // 以太网视频调试通路(网络模块; UDP: 192.168.1.66 -> 192.168.1.100, 端口 6000,
    // 1280x720 每帧都发 = 30fps, 1920包/帧, 约697Mbps; 电脑端: eth_video_rx.py --width 1280 --height 720)
    cvp_eth_dbg #(
        .ENABLE_STATUS(1),.STATUS_BITS(1536),
        .IMG_W       ( 1280      ),
        .IMG_H       ( 720       ),
        .FRAME_SKIP  ( 1         ),
        .DATA_BYTES  ( 1440      ),
        .GEN_TESTPAT ( 0         ),   // 0=相机流(彩条分诊已于 v11b 验证通路正确)
        .PHY_ADDR    ( 5'd1      )
    ) u_eth_dbg (
        .i_frame_id(pack_frame_id),.i_status_data(adv_status),.i_status_valid(adv_status_valid),.o_status_ready(adv_status_ready),
        .o_pixel_overflow(net_overflow),.o_frame_tx_done(net_tx_done),.o_frame_tx_id(net_tx_fid),
        .i_clk_pix      ( S_100m_clk        ),   // v13d: cvp ISP 在 100M 域
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

    // ETHB 发送镜像: 与 ETHA 完全相同的 RGMII TX(同一 MAC, 两颗 PHY 发出相同
    // UDP 流)。RGMII DDR 数据/ODDR 原语输出 fanout=2, 125M DDR 下无时序影响。
    // 命令通路(RX)仅在 ETHA; ETH_RST_B(H2) 两路 PHY 共用, 上面已恒 1。
    assign {O_ethb_rgmii_txd, O_ethb_rgmii_tx_ctl, O_ethb_rgmii_txc} =
           {O_eth_rgmii_txd,  O_eth_rgmii_tx_ctl,  O_eth_rgmii_txc};
    // ETHB MDC 复用 A 口 MDC(ETHA 只读监测总线); ETHB_MDIO(R5) 留空不接
    assign O_ethb_mdc = O_eth_mdc;

endmodule
