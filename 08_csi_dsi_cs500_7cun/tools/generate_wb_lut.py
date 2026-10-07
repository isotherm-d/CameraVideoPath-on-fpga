"""Generate the synthesizable 100 K temperature table; run after calibration."""
import argparse
import re
from pathlib import Path
from color_model import load_profile, temperature_gains

OUTPUT = Path(__file__).resolve().parents[1] / "user_source/hdl_source/isp2/wb_kelvin.v"
TOP = OUTPUT.parents[1] / "design_top_wrapper.v"


def synchronized_top():
    text = TOP.read_text(encoding="utf-8")
    value = load_profile()["default_exposure"]
    if not 62 <= value <= 1800:
        raise ValueError("Default exposure must be 62..1800")
    text, count = re.subn(r"(\.AE_EXP_CODE\s*\(\s*16'd)\d+(\s*\))",
                         lambda m: m[1] + str(value) + m[2], text)
    if count != 1:
        raise ValueError("Expected exactly one top-level default exposure")
    return text


def render():
    profile = load_profile()
    entries = []
    for hk in range(25, 101):
        r, _, b = temperature_gains(hk * 100, profile)
        entries.append(f"            7'd{hk}: gains = {{9'd{r}, 9'd{b}}};")
    r, _, b = temperature_gains(profile["reference_kelvin"], profile)
    return '''`timescale 1ns/1ns
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
''' + "\n".join(entries) + f'''
            default: gains = {{9'd{r}, 9'd{b}}};
        endcase
    end
    reg [17:0] stage1;
    reg valid1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            stage1 <= {{9'd{r}, 9'd{b}}};
            valid1 <= 1'b0; o_valid <= 1'b0;
            o_gain_r <= 9'd{r}; o_gain_b <= 9'd{b};
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
        .I_kelvin_hk(I_preset ? 7'd{profile['reference_kelvin'] // 100} : I_kelvin),
        .o_valid(), .o_gain_r(temp_r), .o_gain_b(temp_b)
    );
    assign O_r = manual_rgb ? I_r : temp_r;
    assign O_g = manual_rgb ? I_g : 9'd256;
    assign O_b = manual_rgb ? I_b : temp_b;
    assign O_swap = I_swap;
endmodule
'''


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = render()
    if args.check:
        if OUTPUT.read_text(encoding="utf-8") != source or TOP.read_text(encoding="utf-8") != synchronized_top():
            raise SystemExit("White-balance RTL differs from calibration profile")
        print("WB_LUT_PROFILE_MATCH")
    else:
        OUTPUT.write_text(source, encoding="utf-8", newline="\n")
        TOP.write_text(synchronized_top(), encoding="utf-8", newline="\n")
        print(OUTPUT)
