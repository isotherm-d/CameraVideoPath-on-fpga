// v25: Bayer interpolation follows the actual window-centre coordinates.
// Input RAW lattice: 0=BGGR, 1=GBRG, 2=GRBG, 3=RGGB.
`timescale 1ns/1ps
module cvp_demosaic #(
    parameter IMG_W=1024, IMG_H=600,
    parameter [1:0] BAYER_PATTERN=2'd0
) (
    input i_clk, i_rst_n, i_valid,
    input [9:0] i_raw, input i_frame_start,
    output reg o_valid, output reg [23:0] o_rgb, output reg o_frame_start
);
    wire win_valid, win_fs, centre_x_odd, centre_y_odd;
    wire [9:0] p00,p01,p02,p10,p11,p12,p20,p21,p22;
    imgproc_win3x3 #(.IMG_W(IMG_W),.IMG_H(IMG_H),.DW(10)) window (
        .i_clk(i_clk),.i_rst_n(i_rst_n),.i_valid(i_valid),
        .i_data(i_raw),.i_frame_start(i_frame_start),
        .o_valid(win_valid),.o_frame_start(win_fs),
        .o_center_x_odd(centre_x_odd),.o_center_y_odd(centre_y_odd),
        .o_p00(p00),.o_p01(p01),.o_p02(p02),
        .o_p10(p10),.o_p11(p11),.o_p12(p12),
        .o_p20(p20),.o_p21(p21),.o_p22(p22)
    );
    wire [1:0] phase={centre_y_odd,centre_x_odd} ^ BAYER_PATTERN;
    wire [11:0] cross_sum={2'b0,p01}+{2'b0,p10}+{2'b0,p12}+{2'b0,p21};
    wire [11:0] diagonal_sum={2'b0,p00}+{2'b0,p02}+{2'b0,p20}+{2'b0,p22};
    wire [11:0] vertical_sum={2'b0,p01}+{2'b0,p21};
    wire [11:0] horizontal_sum={2'b0,p10}+{2'b0,p12};
    reg [11:0] red,green,blue;
    always @* begin
        case(phase)
            2'b00: begin // B centre
                blue={2'b0,p11};
                green=(cross_sum+12'd2)>>2;
                red=(diagonal_sum+12'd2)>>2;
            end
            2'b01: begin // G on a B row; R above/below, B left/right
                green={2'b0,p11};
                red=(vertical_sum+12'd1)>>1;
                blue=(horizontal_sum+12'd1)>>1;
            end
            2'b10: begin // G on an R row; B above/below, R left/right
                green={2'b0,p11};
                blue=(vertical_sum+12'd1)>>1;
                red=(horizontal_sum+12'd1)>>1;
            end
            default: begin // R centre
                red={2'b0,p11};
                green=(cross_sum+12'd2)>>2;
                blue=(diagonal_sum+12'd2)>>2;
            end
        endcase
    end
    always @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            o_valid<=0; o_rgb<=0; o_frame_start<=0;
        end else begin
            o_valid<=win_valid;
            o_frame_start<=win_valid && win_fs;
            if(win_valid) o_rgb<={red[9:2],green[9:2],blue[9:2]};
        end
    end
endmodule
