`timescale 1ns / 1ps
/*=============================================================================
 * tb_osd —— OSD 叠加模块单模块 RTL 仿真判定(v2)
 * 视频源恒黑; 输出侧用 O_de 自建 out_x/out_y 坐标(与流水线延迟无关):
 *   期望  窗口 rows 58..151 / cols 1103..1248 内非黑像素数 == hex alpha=1 数
 *         窗口外必须全黑(透传)
 *===========================================================================*/
module tb_osd;

    reg clk = 0;
    always #6.667 clk = ~clk;   // 75MHz

    reg rstn = 0;
    initial #200 rstn = 1;

    wire vs, hs, de;
    uivtc #(
        .H_ActiveSize(1280          ),
        .H_SyncStart (1280+88       ),
        .H_SyncEnd   (1280+88+44    ),
        .H_FrameSize (1280+88+44+239),
        .V_ActiveSize(720           ),
        .V_SyncStart (720+4         ),
        .V_SyncEnd   (720+4+5       ),
        .V_FrameSize (720+4+5+28    )
    ) u_vtc (
        .I_vtc_rstn(rstn),
        .I_vtc_clk (clk),
        .O_vtc_vs  (vs),
        .O_vtc_hs  (hs),
        .O_vtc_de  (de)
    );

    wire [23:0] rgb_out;
    wire        de_out;
    osd_anlogic_logo #(
        .IMG_WIDTH(1280),
        .X_POS(1096), .Y_POS(24),
        .CROP_X(7), .CROP_Y(34), .CROP_W(146), .CROP_H(94)
    ) u_osd (
        .I_clk  (clk),
        .I_rst_n(rstn),
        .I_vs   (vs),
        .I_de   (de),
        .I_rgb  (24'h000000),
        .O_rgb  (rgb_out),
        .O_de   (de_out)
    );

    /* 输出域坐标: O_de 期数 x, 行尾进 y, vs 清零 */
    reg [11:0] out_x = 0, out_y = 0;
    always @(posedge clk) begin
        if (!rstn)          begin out_x <= 0; out_y <= 0; end
        else if (vs)        begin out_x <= 0; out_y <= 0; end
        else if (de_out)    out_x <= out_x + 1;
        else if (out_x != 0) begin out_x <= 0; out_y <= out_y + 1; end
    end

    integer seen = 0, miss = 0, outside_bad = 0;
    integer fx = -1, fy = -1, lx = -1, ly = -1;
    integer frame = 0;
    reg prev_vs = 0;

    /* 落点账本: 期望/实际 两个 13724 位图 */
    reg exp_hit [0:13723];
    reg act_hit [0:13723];
    reg [23:0] act_color [0:13723];
    reg [8:0] mem_exp [0:13723];
    reg [23:0] pal_lut [0:255];
    integer k;
    integer c2;
    integer diff_cnt;
    initial begin
        for (k = 0; k < 13724; k = k + 1) begin
            exp_hit[k] = 1'b0;
            act_hit[k] = 1'b0;
        end
        // 期望集合 = hex alpha=1
        $readmemh("logo_mem.hex", mem_exp);
        for (k = 0; k < 13724; k = k + 1)
            exp_hit[k] = mem_exp[k][8];
        $readmemh("pal.hex", pal_lut);
    end

    always @(negedge clk) begin
        if (rstn && de_out && frame >= 1) begin
            if (out_y >= 58 && out_y < 152 && out_x >= 1103 && out_x < 1249) begin
                if (rgb_out !== 24'h000000) begin
                    seen = seen + 1;
                    if (fx < 0) begin fx = out_x; fy = out_y; end
                    lx = out_x; ly = out_y;
                    act_hit[(out_y - 58) * 146 + (out_x - 1103)] = 1'b1;
                    act_color[(out_y - 58) * 146 + (out_x - 1103)] = rgb_out;
                end else
                    miss = miss + 1;
            end else if (rgb_out !== 24'h000000) begin
                outside_bad = outside_bad + 1;
                if (outside_bad < 6)
                    $display("[BAD] x=%0d y=%0d out=%h", out_x, out_y, rgb_out);
            end
        end
    end

    always @(posedge clk) begin
        prev_vs <= vs;
        if (vs && !prev_vs) begin
            if (frame > 0)
                $display("[FRAME %0d] seen=%0d miss=%0d outside_bad=%0d",
                          frame, seen, miss, outside_bad);
            frame = frame + 1;
            if (frame == 3) begin
                #1000;
                diff_cnt = 0;
                $display("=========================================");
                for (k = 0; k < 13724; k = k + 1)
                    if (exp_hit[k] !== act_hit[k]) begin
                        if (diff_cnt < 14) begin
                            if (exp_hit[k])
                                $display("[DIFF] crop(%0d,%0d) 期望色=%h(idx %02x, addr %0d) 实际=%b",
                                          k % 146, k / 146, pal_lut[mem_exp[k][7:0]],
                                          mem_exp[k][7:0], k, act_hit[k]);
                            else
                                $display("[DIFF] crop(%0d,%0d) 期望=透明 实际色=%h",
                                          k % 146, k / 146, act_color[k]);
                        end
                        diff_cnt = diff_cnt + 1;
                    end
                $display("logo 像素: seen=%0d (期望 6387), miss=%0d, 窗口外误点=%0d, 差异=%0d",
                          seen, miss, outside_bad, diff_cnt);
                $display("首点(%0d,%0d) 末点(%0d,%0d)  期望范围 x[1103..1248] y[58..151]",
                          fx, fy, lx, ly);
                if (seen == 6387 && miss == 0 && outside_bad == 0)
                    $display("OSD-SIM: PASS  (RTL 层 logo 完整正确显示)");
                else
                    $display("OSD-SIM: FAIL");
                $display("=========================================");
                // dump 前 6 行位图供目视对比
                for (k = 0; k < 6; k = k + 1) begin
                    $write("EXP r%0d: ", k);
                    for (c2 = 0; c2 < 146; c2 = c2 + 1)
                        $write("%c", exp_hit[k*146+c2] ? "#" : ".");
                    $write("
ACT r%0d: ", k);
                    for (c2 = 0; c2 < 146; c2 = c2 + 1)
                        $write("%c", act_hit[k*146+c2] ? "#" : ".");
                    $write("
");
                end
                $finish;
            end
        end
    end

    initial begin
        #60000000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
