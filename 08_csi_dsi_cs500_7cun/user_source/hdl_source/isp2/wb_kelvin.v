`timescale 1ns/1ns
// v25: generated from tools/wb_profile.json by tools/generate_wb_lut.py.
// Calibrated sensor balance + reciprocal-temperature interpolation, 100 K steps.
// No run-time division or signed/unsigned interpolation arithmetic.
module wb_kelvin (
    input I_clk, input I_rst_n, input I_en,
    input [6:0] I_kelvin_hk,
    output reg o_valid,
    output reg [8:0] o_gain_r, output reg [8:0] o_gain_b
);
    wire [6:0] hk = I_kelvin_hk < 7'd25 ? 7'd25 :
                    I_kelvin_hk > 7'd100 ? 7'd100 : I_kelvin_hk;
    reg [17:0] gains;
    always @* begin
        case (hk)
            7'd25: gains = {9'd180, 9'd511};
            7'd26: gains = {9'd188, 9'd511};
            7'd27: gains = {9'd196, 9'd511};
            7'd28: gains = {9'd203, 9'd511};
            7'd29: gains = {9'd209, 9'd511};
            7'd30: gains = {9'd215, 9'd511};
            7'd31: gains = {9'd221, 9'd511};
            7'd32: gains = {9'd227, 9'd511};
            7'd33: gains = {9'd233, 9'd511};
            7'd34: gains = {9'd238, 9'd511};
            7'd35: gains = {9'd243, 9'd511};
            7'd36: gains = {9'd249, 9'd511};
            7'd37: gains = {9'd254, 9'd511};
            7'd38: gains = {9'd258, 9'd511};
            7'd39: gains = {9'd263, 9'd511};
            7'd40: gains = {9'd267, 9'd511};
            7'd41: gains = {9'd272, 9'd511};
            7'd42: gains = {9'd276, 9'd511};
            7'd43: gains = {9'd280, 9'd511};
            7'd44: gains = {9'd284, 9'd511};
            7'd45: gains = {9'd288, 9'd511};
            7'd46: gains = {9'd291, 9'd511};
            7'd47: gains = {9'd295, 9'd511};
            7'd48: gains = {9'd298, 9'd511};
            7'd49: gains = {9'd302, 9'd511};
            7'd50: gains = {9'd305, 9'd511};
            7'd51: gains = {9'd308, 9'd511};
            7'd52: gains = {9'd311, 9'd511};
            7'd53: gains = {9'd314, 9'd511};
            7'd54: gains = {9'd317, 9'd511};
            7'd55: gains = {9'd320, 9'd511};
            7'd56: gains = {9'd322, 9'd504};
            7'd57: gains = {9'd325, 9'd497};
            7'd58: gains = {9'd327, 9'd490};
            7'd59: gains = {9'd330, 9'd484};
            7'd60: gains = {9'd332, 9'd477};
            7'd61: gains = {9'd334, 9'd472};
            7'd62: gains = {9'd337, 9'd466};
            7'd63: gains = {9'd339, 9'd461};
            7'd64: gains = {9'd342, 9'd456};
            7'd65: gains = {9'd344, 9'd451};
            7'd66: gains = {9'd346, 9'd446};
            7'd67: gains = {9'd348, 9'd441};
            7'd68: gains = {9'd350, 9'd437};
            7'd69: gains = {9'd352, 9'd432};
            7'd70: gains = {9'd353, 9'd428};
            7'd71: gains = {9'd355, 9'd424};
            7'd72: gains = {9'd357, 9'd421};
            7'd73: gains = {9'd358, 9'd417};
            7'd74: gains = {9'd360, 9'd414};
            7'd75: gains = {9'd361, 9'd410};
            7'd76: gains = {9'd363, 9'd408};
            7'd77: gains = {9'd364, 9'd405};
            7'd78: gains = {9'd366, 9'd402};
            7'd79: gains = {9'd367, 9'd399};
            7'd80: gains = {9'd368, 9'd396};
            7'd81: gains = {9'd370, 9'd394};
            7'd82: gains = {9'd371, 9'd391};
            7'd83: gains = {9'd372, 9'd389};
            7'd84: gains = {9'd373, 9'd387};
            7'd85: gains = {9'd375, 9'd384};
            7'd86: gains = {9'd376, 9'd382};
            7'd87: gains = {9'd377, 9'd380};
            7'd88: gains = {9'd378, 9'd378};
            7'd89: gains = {9'd379, 9'd376};
            7'd90: gains = {9'd380, 9'd373};
            7'd91: gains = {9'd381, 9'd372};
            7'd92: gains = {9'd383, 9'd370};
            7'd93: gains = {9'd384, 9'd368};
            7'd94: gains = {9'd385, 9'd367};
            7'd95: gains = {9'd386, 9'd365};
            7'd96: gains = {9'd387, 9'd364};
            7'd97: gains = {9'd388, 9'd362};
            7'd98: gains = {9'd389, 9'd361};
            7'd99: gains = {9'd390, 9'd359};
            7'd100: gains = {9'd391, 9'd358};
            default: gains = {9'd344, 9'd451};
        endcase
    end
    reg [17:0] stage1;
    reg valid1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            stage1 <= {9'd344, 9'd451};
            valid1 <= 1'b0; o_valid <= 1'b0;
            o_gain_r <= 9'd344; o_gain_b <= 9'd451;
        end else begin
            valid1 <= I_en;
            if (I_en) stage1 <= gains;
            o_valid <= valid1;
            if (valid1) begin
                o_gain_r <= stage1[17:9]; o_gain_b <= stage1[8:0];
            end
        end
    end
endmodule

// Retain the existing command protocol: cmd6=1 preset; cmd6=0 manual.
// In manual mode cmd7=0 selects RGB gains, cmd7=25..100 selects temperature.
module cvp_wb_select (
    input I_clk, input I_rst_n, input I_preset,
    input [6:0] I_kelvin, input [8:0] I_r, input [8:0] I_g, input [8:0] I_b,
    input I_swap,
    output [8:0] O_r, output [8:0] O_g, output [8:0] O_b, output O_swap
);
    wire [8:0] temp_r, temp_b;
    wire manual_rgb = !I_preset && I_kelvin == 7'd0;
    wb_kelvin temperature (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_en(1'b1),
        .I_kelvin_hk(I_preset ? 7'd65 : I_kelvin),
        .o_valid(), .o_gain_r(temp_r), .o_gain_b(temp_b)
    );
    assign O_r = manual_rgb ? I_r : temp_r;
    assign O_g = manual_rgb ? I_g : 9'd256;
    assign O_b = manual_rgb ? I_b : temp_b;
    assign O_swap = I_swap;
endmodule
