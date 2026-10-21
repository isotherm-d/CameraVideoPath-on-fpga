module	rgmii_cdc
(
	input	wire			speed_10_100	,
	input	wire			I_rst			,
	input	wire			I_gmii_rclk		,
	input	wire			I_gmii_rvalid	,
	input	wire	[7:0]	I_gmii_rdata	,

	input	wire			I_gmii_tclk		,
	output	reg				O_gmii_tvalid	,
	output	reg		[7:0]	O_gmii_tdata	,

	input	wire			I_rx_clk		,
	output	reg				O_rx_valid		,
	output	reg		[7:0]	O_rx_data		,

	input	wire			I_tx_clk		,
	input	wire			I_tx_valid		,
	input	wire	[7:0]	I_tx_data		
);

reg		[7:0]		tx_gap;
reg		[15:0]		tx_len_fifo_din;
wire				tx_len_fifo_wren;
wire				tx_len_fifo_rdemtpy;
reg					tx_len_fifo_rden;
wire	[15:0]		tx_len_fifo_dout;
reg					tx_data_fifo_rden;
wire	[7:0]		tx_data_fifo_dout;

reg		[15:0]		tx_len;
reg					tx_valid_reg;
reg					tcnt_10_100;
reg		[15:0]		tx_cnt;		
reg					tx_lock;
reg					tx_run;
reg					tx_en;

assign	tx_len_fifo_wren	=	tx_valid_reg && ~I_tx_valid;

always@(posedge I_tx_clk)
	tx_valid_reg	<=	I_tx_valid;

always@(posedge I_tx_clk or posedge I_rst) begin
	if(I_rst)
		tx_len_fifo_din	<=	16'd0;
	else if(I_tx_valid)
		tx_len_fifo_din	<=	tx_len_fifo_din + 1'b1;
	else
		tx_len_fifo_din	<=	16'd0;
end


udp_pkg_buf #(
.DATA_WIDTH_W		(8					), 
.DATA_WIDTH_R		(8					), 
.ADDR_WIDTH_W		(12					), 
.ADDR_WIDTH_R		(12					), 
.SHOW_AHEAD_EN		(1'b1				), 
.OUTREG_EN			("NOREG"			)
) 
tx_data_fifo
(
.rst				(I_rst				),
.clkw				(I_tx_clk			),
.we					(I_tx_valid			),
.di					(I_tx_data			),
.clkr				(I_gmii_tclk		),
.re					(tx_data_fifo_rden	),
.dout				(tx_data_fifo_dout	),
.wrusedw			(),
.rdusedw			()
);


udp_pkg_buf #(
.DATA_WIDTH_W		(16					), 
.DATA_WIDTH_R		(16					), 
.ADDR_WIDTH_W		(6					), 
.ADDR_WIDTH_R		(6					), 
.SHOW_AHEAD_EN		(1'b1				), 
.OUTREG_EN			("NOREG"			)
) 
tx_len_fifo
(
.rst				(I_rst				),
.clkw				(I_tx_clk			),
.we					(tx_len_fifo_wren	),
.di					(tx_len_fifo_din	),
.clkr				(I_gmii_tclk		),
.re					(tx_len_fifo_rden	),
.dout				(tx_len_fifo_dout	),
.wrusedw			(),
.rdusedw			(),
.empty_flag			(tx_len_fifo_rdemtpy)
);

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_lock	<=	1'b0;
	else if(!tx_lock && !tx_len_fifo_rdemtpy)
		tx_lock	<=	1'b1;
	else if(tx_cnt == 16'd0 && tx_gap == 8'd10 && ~speed_10_100)
		tx_lock	<=	1'b0;
	else if(tx_cnt == 16'd0 && tx_gap == 8'd22 && speed_10_100)
		tx_lock	<=	1'b0;
	else
		tx_lock	<=	tx_lock;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_len_fifo_rden	<=	1'b0;
	else if(!tx_lock && !tx_len_fifo_rdemtpy)
		tx_len_fifo_rden	<=	1'b1;
	else
		tx_len_fifo_rden	<=	1'b0;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_len	<=	16'd0;
	else if(tx_len_fifo_rden)
		tx_len	<=	tx_len_fifo_dout;
	else
		tx_len	<=	tx_len;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_run	<=	1'b0;
	else if(tx_lock && tx_len_fifo_rden)
		tx_run	<=	1'b1;
	else if(tx_cnt == tx_len - 1'b1 && ~speed_10_100)
		tx_run	<=	1'b0;
	else if(tx_cnt == tx_len - 1'b1 && tcnt_10_100 && speed_10_100)
		tx_run	<=	1'b0;
	else
		tx_run	<=	tx_run;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_data_fifo_rden	<=	1'b0;
	else if(tcnt_10_100 && tx_run)
		tx_data_fifo_rden	<=	1'b1;
	else if(speed_10_100)
		tx_data_fifo_rden	<=	1'b0;
	else if(tx_lock && tx_len_fifo_rden && ~speed_10_100)
		tx_data_fifo_rden	<=	1'b1;
	else if(tx_cnt >= tx_len - 1'b1)
		tx_data_fifo_rden	<=	1'b0;
	else
		tx_data_fifo_rden	<=	tx_data_fifo_rden;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tcnt_10_100	<=	1'b0;
	else if(tx_run && speed_10_100)
		tcnt_10_100	<=	tcnt_10_100 + 1'b1;
	else
		tcnt_10_100	<=	1'b0;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_gap	<=	8'd0;
	else if(~speed_10_100 && tx_gap == 8'd10)
		tx_gap	<=	8'd0;
	else if(speed_10_100 && tx_gap == 8'd22)
		tx_gap	<=	8'd0;
	else if((tx_lock && tx_cnt == tx_len - 1'b1) || tx_gap > 8'd0)
		tx_gap	<=	tx_gap + 1'b1;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_cnt	<=	16'd0;
	else if(tx_cnt == tx_len)
		tx_cnt	<=	16'd0;
	else if(tx_data_fifo_rden)
		tx_cnt	<=	tx_cnt + 1'b1;
	else
		tx_cnt	<=	tx_cnt;
end

always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		tx_en	<=	1'b0;
	else if(tx_run && speed_10_100)
		tx_en	<=	1'b1;
	else if(~tx_run)
		tx_en	<=	1'b0;
end


always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		O_gmii_tvalid	<=	1'b0;
	else if(~speed_10_100)
		O_gmii_tvalid	<=	tx_data_fifo_rden;
	else if(speed_10_100 && ~tx_en)
		O_gmii_tvalid	<=	1'b0;
	else if(speed_10_100 && tx_en)
		O_gmii_tvalid	<=	1'b1;
	else
		O_gmii_tvalid	<=	1'b0;
end


always@(posedge I_gmii_tclk or posedge I_rst) begin
	if(I_rst)
		O_gmii_tdata	<=	8'd0;
	else if(tx_run && ~speed_10_100)
		O_gmii_tdata	<=	tx_data_fifo_dout;
	else if(tx_en && speed_10_100)
		O_gmii_tdata	<=	tcnt_10_100 ? {4'd0,tx_data_fifo_dout[3:0]} : {4'd0,tx_data_fifo_dout[7:4]};
	else
		O_gmii_tdata	<=	8'd0;
end


//==================================================================
//==================================================================


reg		[15:0]		rx_len_fifo_din;
wire				rx_len_fifo_wren;
wire				rx_len_fifo_rdemtpy;
reg					rx_len_fifo_rden;
wire	[15:0]		rx_len_fifo_dout;
reg		[7:0]		rx_data_fifo_din;
reg					rx_data_fifo_wren;
reg					rx_data_fifo_rden;
wire	[7:0]		rx_data_fifo_dout;

reg					gmii_rvalid_reg;
reg		[15:0]		rx_len;
reg		[15:0]		rx_cnt;
reg					rx_lock;
reg					rcnt_10_100;


assign	rx_len_fifo_wren	=	gmii_rvalid_reg && ~I_gmii_rvalid;

always@(posedge I_gmii_rclk)
	gmii_rvalid_reg	<=	I_gmii_rvalid;

always@(posedge I_gmii_rclk or posedge I_rst) begin
	if(I_rst)
		rx_len_fifo_din	<=	0;
	else if(~I_gmii_rvalid)
		rx_len_fifo_din	<=	0;
	else if(I_gmii_rvalid && ~speed_10_100)
		rx_len_fifo_din	<=	rx_len_fifo_din + 1;
	else if(I_gmii_rvalid && speed_10_100 && rcnt_10_100)
		rx_len_fifo_din	<=	rx_len_fifo_din + 1;
	else
		rx_len_fifo_din	<=	rx_len_fifo_din;
end

always@(posedge I_gmii_rclk or posedge I_rst) begin
	if(I_rst)
		rcnt_10_100	<=	1'b0;
	else if(I_gmii_rvalid && speed_10_100)
		rcnt_10_100	<=	rcnt_10_100 + 1'b1;
	else
		rcnt_10_100	<=	1'b0;
end

always@(posedge I_gmii_rclk or posedge I_rst) begin
	if(I_rst)
		rx_data_fifo_wren	<=	1'b0;
	else if(~speed_10_100)
		rx_data_fifo_wren	<=	I_gmii_rvalid;
	else if(speed_10_100)
		rx_data_fifo_wren	<=	rcnt_10_100;
end

always@(posedge I_gmii_rclk or posedge I_rst) begin
	if(I_rst)
		rx_data_fifo_din	<=	8'd0;
	else if(speed_10_100)
		rx_data_fifo_din	<=	{I_gmii_rdata[3:0], rx_data_fifo_din[7:4]};
	else
		rx_data_fifo_din	<=	I_gmii_rdata;
end


udp_pkg_buf #(
.DATA_WIDTH_W		(8					), 
.DATA_WIDTH_R		(8					), 
.ADDR_WIDTH_W		(12					), 
.ADDR_WIDTH_R		(12					), 
.SHOW_AHEAD_EN		(1'b1				), 
.OUTREG_EN			("NOREG"			)
) 
rx_data_fifo
(
.rst				(I_rst				),
.clkw				(I_gmii_rclk		),
.we					(rx_data_fifo_wren	),
.di					(rx_data_fifo_din	),
.clkr				(I_rx_clk			),
.re					(rx_data_fifo_rden	),
.dout				(rx_data_fifo_dout	),
.wrusedw			(),
.rdusedw			()
);


udp_pkg_buf #(
.DATA_WIDTH_W		(16					), 
.DATA_WIDTH_R		(16					), 
.ADDR_WIDTH_W		(6					), 
.ADDR_WIDTH_R		(6					), 
.SHOW_AHEAD_EN		(1'b1				), 
.OUTREG_EN			("NOREG"			)
) 
rx_len_fifo
(
.rst				(I_rst				),
.clkw				(I_gmii_rclk		),
.we					(rx_len_fifo_wren	),
.di					(rx_len_fifo_din	),
.clkr				(I_rx_clk			),
.re					(rx_len_fifo_rden	),
.dout				(rx_len_fifo_dout	),
.wrusedw			(),
.rdusedw			(),
.empty_flag			(rx_len_fifo_rdemtpy)
);

always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		rx_lock	<=	1'b0;
	else if(!rx_lock && !rx_len_fifo_rdemtpy)
		rx_lock	<=	1'b1;
	else if(rx_cnt == rx_len - 1'b1)
		rx_lock	<=	1'b0;
	else
		rx_lock	<=	rx_lock;
end

always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		rx_len_fifo_rden	<=	1'b0;
	else if(!rx_lock && !rx_len_fifo_rdemtpy)
		rx_len_fifo_rden	<=	1'b1;
	else
		rx_len_fifo_rden	<=	1'b0;
end

always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		rx_len	<=	16'd0;
	else if(rx_len_fifo_rden)
		rx_len	<=	rx_len_fifo_dout;
	else
		rx_len	<=	rx_len;
end


always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		rx_data_fifo_rden	<=	1'b0;
	else if(rx_lock && rx_len_fifo_rden)
		rx_data_fifo_rden	<=	1'b1;
	else if(rx_cnt == rx_len - 1'b1)
		rx_data_fifo_rden	<=	1'b0;
	else
		rx_data_fifo_rden	<=	rx_data_fifo_rden;
end

always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		rx_cnt	<=	16'd0;
	else if(rx_cnt == rx_len - 1)
		rx_cnt	<=	16'd0;
	else if(rx_data_fifo_rden)
		rx_cnt	<=	rx_cnt + 1'b1;
	else
		rx_cnt	<=	rx_cnt;
end

always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		O_rx_valid	<=	1'b0;
	else if(rx_data_fifo_rden)
		O_rx_valid	<=	1'b1;
	else
		O_rx_valid	<=	1'b0;
end


always@(posedge I_rx_clk or posedge I_rst) begin
	if(I_rst)
		O_rx_data	<=	8'd0;
	else if(rx_data_fifo_rden)
		O_rx_data	<=	rx_data_fifo_dout;
	else
		O_rx_data	<=	8'd0;
end



endmodule