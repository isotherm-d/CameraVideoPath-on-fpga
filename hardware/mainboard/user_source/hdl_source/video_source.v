module video_source (
    input wire        I_clk,
    input wire        I_rst,
    input wire        I_config_done,

    output wire       O_rgb24b_vsync,
    output wire       O_rgb24b_hsync,
    output wire       O_rgb24b_de,
    output wire[23:0] O_rgb24b_data
);


    parameter  HTOTAL = 1344;
    parameter  VTOTAL = 635;

    parameter  HSA    = 24;  
    parameter  HBP    = 136;  
    parameter  HFP    = 160;  

    parameter  VSA    = 2;   
    parameter  VBP    = 21;  
    parameter  VFP    = 12;   

    wire     S_24b_vsync;
    wire     S_24b_hsync;
    wire     video_rst;
    reg      S_vsync_1d;
    wire     S_vsync_p_edge;
	reg[7:0] S_frame_cnt;
	reg[3:0] S_tgb_mode;

    always @(posedge I_clk) begin
        S_vsync_1d <= O_rgb24b_vsync;
    end

    assign S_vsync_p_edge = ~S_vsync_1d & O_rgb24b_vsync;



	always @ (posedge I_clk or posedge I_rst) begin
		if(I_rst)	
			S_frame_cnt <= 'd0;		
		else			
			if(S_vsync_p_edge)
				if(S_frame_cnt == 'd120)			
					S_frame_cnt <= 'd0;				
				else					
					S_frame_cnt <= S_frame_cnt + 1'b1;								
			else					
				S_frame_cnt <= S_frame_cnt;
	end 

	always @ (posedge I_clk or posedge I_rst) begin
		if(I_rst)	
			S_tgb_mode <= 'd0;		
		else			
			if(S_vsync_p_edge && S_frame_cnt == 'd120)		
				if(S_tgb_mode == 'd9)			
					S_tgb_mode <= 'd0;								
				else					
					S_tgb_mode <= S_tgb_mode + 1'b1;				
			else					
				S_tgb_mode <= S_tgb_mode;
	end 



    assign O_rgb24b_vsync = ~S_24b_vsync;
    assign O_rgb24b_hsync = ~S_24b_hsync;

    assign video_rst = I_rst | (~I_config_done);

    video_tpg  #(
        .HTOTAL ( HTOTAL ),
        .HSA    ( HSA    ),
        .HBP    ( HBP    ),
        .HFP    ( HFP    ),
   
        .VTOTAL ( VTOTAL ),
        .VSA    ( VSA    ),
        .VBP    ( VBP    ),
        .VFP    ( VFP    )
    )u_video_tpg_8001280(
        .PCLK     ( I_clk         ),
        .Reset    ( video_rst     ),

        .DEN_TPG  ( 1'b1          ),
        .TPG_mode ( S_tgb_mode    ),

        .PDEN     ( O_rgb24b_de   ),
        .HSYNC    ( S_24b_hsync   ),
        .VSYNC    ( S_24b_vsync   ),
        .PDATA    ( O_rgb24b_data )
    );

    
endmodule