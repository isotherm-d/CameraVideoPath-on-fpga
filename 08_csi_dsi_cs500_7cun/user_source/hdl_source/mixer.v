

module mixer ( 
    input wire        I_clk,
    
    input wire        I_video_vsync,
    input wire        I_video_hsync,
    input wire        I_video_de,

    output wire       O_vdieo_rd_en,
    input wire[23:0]  I_video_rd_data,

    output reg        O_mixer_vsync,
    output reg        O_mixer_hsync,
    output reg        O_mixer_de,
    output reg[23:0]  O_mixer_data
);

    reg S_video_vsync_1d;
    reg S_video_vsync_2d;
    reg S_video_hsync_1d;
    reg S_video_hsync_2d;
    reg S_video_de_1d;
    reg S_video_de_2d;

    assign O_vdieo_rd_en = I_video_de;

    always @(posedge I_clk) begin
        S_video_vsync_1d  <= I_video_vsync;
        S_video_vsync_2d  <= S_video_vsync_1d;
        O_mixer_vsync     <= S_video_vsync_2d;

        S_video_hsync_1d <= I_video_hsync;
        S_video_hsync_2d <= S_video_hsync_1d;
        O_mixer_hsync    <= S_video_hsync_2d;

        S_video_de_1d  <= I_video_de;
        S_video_de_2d  <= S_video_de_1d;
        O_mixer_de     <= S_video_de_2d;

        O_mixer_data   <= I_video_rd_data;
    end
    
endmodule