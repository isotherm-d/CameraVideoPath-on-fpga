`timescale 1ns / 1ps

module cvp_fx_median #(parameter CHANNEL_BITS=8) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire        i_valid,
    input  wire        i_frame_start,
    input  wire [23:0] i_p00, i_p01, i_p02,
    input  wire [23:0] i_p10, i_p11, i_p12,
    input  wire [23:0] i_p20, i_p21, i_p22,

    output reg         o_valid,
    output reg         o_frame_start,
    output reg  [23:0] o_rgb
);

    /* Comparisons operate on the selected MSBs; monotone quantization
     * commutes with this min/max network. CHANNEL_BITS=8 is the legacy mode. */
    function [CHANNEL_BITS-1:0] max2;
        input [CHANNEL_BITS-1:0] a, b;
        max2 = (a > b) ? a : b;
    endfunction
    function [CHANNEL_BITS-1:0] min2;
        input [CHANNEL_BITS-1:0] a, b;
        min2 = (a < b) ? a : b;
    endfunction
    /* 3 数取中：max( min(a,b), min(max(a,b), c) ) */
    function [CHANNEL_BITS-1:0] med3;
        input [CHANNEL_BITS-1:0] a, b, c;
        reg   [CHANNEL_BITS-1:0] lo_ab, hi_ab;
        begin
            lo_ab = min2(a, b);
            hi_ab = max2(a, b);
            med3  = max2(lo_ab, min2(hi_ab, c));
        end
    endfunction

    /* ---------- 级 1 寄存器：每行排序结果（hi/md/lo x 3 行 x 3 通道打包 24bit） ---------- */
    reg [3*CHANNEL_BITS-1:0] r1_hi0, r1_md0, r1_lo0;
    reg [3*CHANNEL_BITS-1:0] r1_hi1, r1_md1, r1_lo1;
    reg [3*CHANNEL_BITS-1:0] r1_hi2, r1_md2, r1_lo2;
    reg        r1_valid, r1_fs;
    /* ---------- 级 2 寄存器：行间两两归约 + 行 2 排序结果直通（级 3 要用） ---------- */
    reg [3*CHANNEL_BITS-1:0] r2_h01, r2_l01, r2_m01, r2_m02;
    reg [3*CHANNEL_BITS-1:0] r2_hi2, r2_md2, r2_lo2;
    reg        r2_valid, r2_fs;
    /* ---------- 级 3 寄存器：列归约结果 (h, m, l) ---------- */
    reg [3*CHANNEL_BITS-1:0] r3_h, r3_m, r3_l;
    reg        r3_valid, r3_fs;

    integer    c;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r1_hi0 <= 24'd0; r1_md0 <= 24'd0; r1_lo0 <= 24'd0;
            r1_hi1 <= 24'd0; r1_md1 <= 24'd0; r1_lo1 <= 24'd0;
            r1_hi2 <= 24'd0; r1_md2 <= 24'd0; r1_lo2 <= 24'd0;
            r1_valid <= 1'b0; r1_fs <= 1'b0;
            r2_h01 <= 24'd0; r2_l01 <= 24'd0; r2_m01 <= 24'd0; r2_m02 <= 24'd0;
            r2_hi2 <= 24'd0; r2_md2 <= 24'd0; r2_lo2 <= 24'd0;
            r2_valid <= 1'b0; r2_fs <= 1'b0;
            r3_h <= 24'd0; r3_m <= 24'd0; r3_l <= 24'd0;
            r3_valid <= 1'b0; r3_fs <= 1'b0;
            o_valid <= 1'b0; o_frame_start <= 1'b0;
            o_rgb   <= 24'd0;
        end else begin
            /* ---- 级 1：每行 sort3 ---- */
            r1_valid <= i_valid;
            if (i_valid) r1_fs <= i_frame_start;
            /* ---- 级 2：两两归约 ---- */
            r2_valid <= r1_valid;
            if (r1_valid) r2_fs <= r1_fs;
            /* ---- 级 3：列归约 ---- */
            r3_valid <= r2_valid;
            if (r2_valid) r3_fs <= r2_fs;
            /* ---- 级 4：输出 ---- */
            o_valid <= r3_valid;
            if (r3_valid) o_frame_start <= r3_fs;

            for (c = 0; c < 3; c = c + 1) begin
                /* 级 1 寄存：三行各自 sort3（hi >= md >= lo） */
                if (i_valid) begin
                    r1_hi0[c*CHANNEL_BITS +: CHANNEL_BITS] <= max2(max2(i_p00[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p01[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]), i_p02[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_md0[c*CHANNEL_BITS +: CHANNEL_BITS] <= med3(i_p00[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p01[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p02[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_lo0[c*CHANNEL_BITS +: CHANNEL_BITS] <= min2(min2(i_p00[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p01[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]), i_p02[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_hi1[c*CHANNEL_BITS +: CHANNEL_BITS] <= max2(max2(i_p10[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p11[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]), i_p12[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_md1[c*CHANNEL_BITS +: CHANNEL_BITS] <= med3(i_p10[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p11[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p12[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_lo1[c*CHANNEL_BITS +: CHANNEL_BITS] <= min2(min2(i_p10[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p11[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]), i_p12[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_hi2[c*CHANNEL_BITS +: CHANNEL_BITS] <= max2(max2(i_p20[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p21[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]), i_p22[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_md2[c*CHANNEL_BITS +: CHANNEL_BITS] <= med3(i_p20[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p21[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p22[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                    r1_lo2[c*CHANNEL_BITS +: CHANNEL_BITS] <= min2(min2(i_p20[c*8+8-CHANNEL_BITS +: CHANNEL_BITS], i_p21[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]), i_p22[c*8+8-CHANNEL_BITS +: CHANNEL_BITS]);
                end
                /* 级 2 寄存：行间两两归约 + 行 2 排序结果直通（级 3 用 r2_*，不能再读 r1_*） */
                if (r1_valid) begin
                    r2_h01[c*CHANNEL_BITS +: CHANNEL_BITS] <= min2(r1_hi0[c*CHANNEL_BITS +: CHANNEL_BITS], r1_hi1[c*CHANNEL_BITS +: CHANNEL_BITS]);
                    r2_l01[c*CHANNEL_BITS +: CHANNEL_BITS] <= max2(r1_lo0[c*CHANNEL_BITS +: CHANNEL_BITS], r1_lo1[c*CHANNEL_BITS +: CHANNEL_BITS]);
                    r2_m01[c*CHANNEL_BITS +: CHANNEL_BITS] <= max2(r1_md0[c*CHANNEL_BITS +: CHANNEL_BITS], r1_md1[c*CHANNEL_BITS +: CHANNEL_BITS]);
                    r2_m02[c*CHANNEL_BITS +: CHANNEL_BITS] <= min2(r1_md0[c*CHANNEL_BITS +: CHANNEL_BITS], r1_md1[c*CHANNEL_BITS +: CHANNEL_BITS]);
                    r2_hi2[c*CHANNEL_BITS +: CHANNEL_BITS] <= r1_hi2[c*CHANNEL_BITS +: CHANNEL_BITS];
                    r2_md2[c*CHANNEL_BITS +: CHANNEL_BITS] <= r1_md2[c*CHANNEL_BITS +: CHANNEL_BITS];
                    r2_lo2[c*CHANNEL_BITS +: CHANNEL_BITS] <= r1_lo2[c*CHANNEL_BITS +: CHANNEL_BITS];
                end
                /* 级 3 寄存：列归约成 h/m/l */
                if (r2_valid) begin
                    r3_h[c*CHANNEL_BITS +: CHANNEL_BITS] <= min2(r2_h01[c*CHANNEL_BITS +: CHANNEL_BITS], r2_hi2[c*CHANNEL_BITS +: CHANNEL_BITS]);
                    r3_l[c*CHANNEL_BITS +: CHANNEL_BITS] <= max2(r2_l01[c*CHANNEL_BITS +: CHANNEL_BITS], r2_lo2[c*CHANNEL_BITS +: CHANNEL_BITS]);
                    r3_m[c*CHANNEL_BITS +: CHANNEL_BITS] <= med3(r2_m01[c*CHANNEL_BITS +: CHANNEL_BITS], r2_m02[c*CHANNEL_BITS +: CHANNEL_BITS], r2_md2[c*CHANNEL_BITS +: CHANNEL_BITS]);
                end
                /* 级 4 寄存：输出中值 */
                if (r3_valid)
                    o_rgb[c*8 +: 8] <= {med3(r3_h[c*CHANNEL_BITS +: CHANNEL_BITS], r3_m[c*CHANNEL_BITS +: CHANNEL_BITS], r3_l[c*CHANNEL_BITS +: CHANNEL_BITS]), {(8-CHANNEL_BITS){1'b0}}};
            end
        end
    end

endmodule
