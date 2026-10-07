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
            7'd25: gains = {9'd152, 9'd491};
            7'd26: gains = {9'd159, 9'd491};
            7'd27: gains = {9'd165, 9'd491};
            7'd28: gains = {9'd171, 9'd491};
            7'd29: gains = {9'd177, 9'd491};
            7'd30: gains = {9'd182, 9'd491};
            7'd31: gains = {9'd187, 9'd481};
            7'd32: gains = {9'd192, 9'd473};
            7'd33: gains = {9'd197, 9'd464};
            7'd34: gains = {9'd202, 9'd456};
            7'd35: gains = {9'd206, 9'd449};
            7'd36: gains = {9'd210, 9'd434};
            7'd37: gains = {9'd215, 9'd419};
            7'd38: gains = {9'd219, 9'd406};
            7'd39: gains = {9'd223, 9'd393};
            7'd40: gains = {9'd226, 9'd381};
            7'd41: gains = {9'd230, 9'd371};
            7'd42: gains = {9'd234, 9'd361};
            7'd43: gains = {9'd237, 9'd352};
            7'd44: gains = {9'd240, 9'd344};
            7'd45: gains = {9'd243, 9'd335};
            7'd46: gains = {9'd246, 9'd328};
            7'd47: gains = {9'd250, 9'd321};
            7'd48: gains = {9'd252, 9'd315};
            7'd49: gains = {9'd255, 9'd309};
            7'd50: gains = {9'd258, 9'd303};
            7'd51: gains = {9'd261, 9'd298};
            7'd52: gains = {9'd263, 9'd293};
            7'd53: gains = {9'd266, 9'd288};
            7'd54: gains = {9'd268, 9'd283};
            7'd55: gains = {9'd271, 9'd279};
            7'd56: gains = {9'd273, 9'd275};
            7'd57: gains = {9'd275, 9'd271};
            7'd58: gains = {9'd277, 9'd267};
            7'd59: gains = {9'd279, 9'd264};
            7'd60: gains = {9'd281, 9'd260};
            7'd61: gains = {9'd283, 9'd257};
            7'd62: gains = {9'd285, 9'd254};
            7'd63: gains = {9'd287, 9'd251};
            7'd64: gains = {9'd289, 9'd249};
            7'd65: gains = {9'd291, 9'd246};
            7'd66: gains = {9'd293, 9'd243};
            7'd67: gains = {9'd294, 9'd241};
            7'd68: gains = {9'd296, 9'd238};
            7'd69: gains = {9'd297, 9'd236};
            7'd70: gains = {9'd299, 9'd234};
            7'd71: gains = {9'd300, 9'd231};
            7'd72: gains = {9'd302, 9'd230};
            7'd73: gains = {9'd303, 9'd228};
            7'd74: gains = {9'd304, 9'd226};
            7'd75: gains = {9'd306, 9'd224};
            7'd76: gains = {9'd307, 9'd222};
            7'd77: gains = {9'd308, 9'd221};
            7'd78: gains = {9'd309, 9'd219};
            7'd79: gains = {9'd310, 9'd218};
            7'd80: gains = {9'd311, 9'd216};
            7'd81: gains = {9'd313, 9'd215};
            7'd82: gains = {9'd314, 9'd213};
            7'd83: gains = {9'd315, 9'd212};
            7'd84: gains = {9'd316, 9'd211};
            7'd85: gains = {9'd317, 9'd210};
            7'd86: gains = {9'd318, 9'd208};
            7'd87: gains = {9'd319, 9'd207};
            7'd88: gains = {9'd320, 9'd206};
            7'd89: gains = {9'd321, 9'd205};
            7'd90: gains = {9'd322, 9'd204};
            7'd91: gains = {9'd323, 9'd203};
            7'd92: gains = {9'd324, 9'd202};
            7'd93: gains = {9'd325, 9'd201};
            7'd94: gains = {9'd326, 9'd200};
            7'd95: gains = {9'd326, 9'd199};
            7'd96: gains = {9'd327, 9'd198};
            7'd97: gains = {9'd328, 9'd197};
            7'd98: gains = {9'd329, 9'd197};
            7'd99: gains = {9'd330, 9'd196};
            7'd100: gains = {9'd331, 9'd195};
            default: gains = {9'd291, 9'd246};
        endcase
    end
    reg [17:0] stage1;
    reg valid1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            stage1 <= {9'd291, 9'd246};
            valid1 <= 1'b0; o_valid <= 1'b0;
            o_gain_r <= 9'd291; o_gain_b <= 9'd246;
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
