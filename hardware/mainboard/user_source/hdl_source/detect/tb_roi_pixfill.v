`timescale 1ns / 1ps
/* ============================================================================
 * tb_roi_pixfill —— u_roi_pixfill 单元验证
 *
 * 场景：1280x720 合成帧（灰度可从 RGB 反推），2 个框：
 *   框0 = (100,200)-(131,231) 正好 32x32（满框）
 *   框1 = (500,300)-(510,306) 小框 11x7（不足 32x32，裁剪窗出框部分=旧值/0）
 * 断言：
 *   K1 框0 缓存 1024 字节 == 对应像素的灰度值（逐字节）；
 *   K2 captured[0] 在行 231 流完后置位；
 *   K3 框1 前 7x11 区域灰度正确；K4 captured[1] 置位；
 *   K5 toggle 后标志清零。
 * 灰度公式 g=(R+2G+B)>>2；合成像素 RGB=(x*7%256, y*3%256, 128) 可精确复算。
 * ============================================================================
 */
`timescale 1ns / 1ps

module tb_roi_pixfill;

    localparam W = 1280, H = 720, N_BOX = 10;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         cv = 0;
    reg [11:0]  cx = 0, cy = 0;
    reg [23:0]  crgb;
    reg [N_BOX*48-1:0] box_xy;
    reg         tog = 0;

    wire [N_BOX-1:0] cap;
    wire [7:0]  rd_data;
    reg [3:0]   rdsel = 0;
    reg         rdrst = 0, rdinc = 0;

    u_roi_pixfill #(.N_BOX(N_BOX), .IMG_W(W), .IMG_H(H)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_pix_valid(cv), .i_pix_x(cx), .i_pix_y(cy), .i_pix_rgb(crgb),
        .i_box_xy(box_xy), .i_box_toggle(tog),
        .o_captured(cap),
        .i_rd_sel(rdsel), .o_rd_data(rd_data),
        .i_rd_rst(rdrst), .i_rd_inc(rdinc)
    );

    /* 合成像素与期望灰度（r/g 先截成 8bit 再拼接——integer 直拼会 72bit 截断） */
    function [23:0] px(input integer x, input integer y);
        reg [7:0] r, g;
        begin
            r = (x*7) % 256;
            g = (y*3) % 256;
            px = {r, g, 8'd128};
        end
    endfunction
    function [7:0] gray_of(input integer x, input integer y);
        reg [7:0] r, g;
        begin
            r = (x*7) % 256; g = (y*3) % 256;
            gray_of = (r + {1'b0, g, 1'b0} + 8'd128) >> 2;
        end
    endfunction

    integer errors = 0, chk = 0;
    task check(input [255:0] name, input ok);
        begin
            chk = chk + 1;
            if (!ok) begin errors = errors + 1; $display("[FAIL] %0s", name); end
            else     $display("[PASS] %0s", name);
        end
    endtask

    /* 流一整帧（negedge 驱动激励，DUT posedge 采样，无竞态） */
    integer px_i;
    task send_frame;
        begin
            @(negedge clk); cv = 1; cx = 0; cy = 0; crgb = px(0,0);
            @(negedge clk);
            for (px_i = 1; px_i < W*H; px_i = px_i + 1) begin
                cx = px_i % W;
                cy = px_i / W;
                crgb = px(cx, cy);
                @(negedge clk);
            end
            cv = 0;
            repeat (100) @(posedge clk);
        end
    endtask

    integer i, j, bad;

    /* 捕获事件探针：框0 前 10 次写（层级引用 DUT 内部信号） */
    integer cap10 = 0;
    always @(posedge clk) begin
        if (rst_n && cv && dut.w_hit[0] && cap10 < 10) begin
            cap10 = cap10 + 1;
            $display("[CAP ] t=%0t cx=%0d cy=%0d crgb=%h w_addr=%0d w_gray=%0d",
                     $time, cx, cy, crgb, dut.w_addr[0], dut.w_gray);
        end
    end

    initial begin
        box_xy = {N_BOX*48{1'b1}};
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        /* 设框 + toggle（帧 N 末） */
        box_xy[47:36] = 100; box_xy[35:24] = 200; box_xy[23:12] = 131; box_xy[11:0] = 231;   // 框0 满 32x32
        box_xy[95:84] = 500; box_xy[83:72] = 300; box_xy[71:60] = 510; box_xy[59:48] = 306; // 框1 11x7
        for (i = 2; i < N_BOX; i = i + 1)
            box_xy[i*48 +: 48] = {4{12'hFFF}};
        @(posedge clk); tog = 1; @(posedge clk); tog = 0;

        /* 流帧 N+1（pixfill 捕获） */
        send_frame;

        check("K2 captured[0] 置位", cap[0] === 1'b1);
        check("K4 captured[1] 置位", cap[1] === 1'b1);

        /* 逐字节比对框0（rdinc 同步驱动：高电平跨一个 posedge） */
        rdsel = 0; bad = 0;
        for (j = 0; j < 32; j = j + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                @(posedge clk); #(1);
                if (rd_data !== gray_of(100+i, 200+j)) begin
                    bad = bad + 1;
                    if (bad <= 5)
                        $display("[DBG ] mismatch j=%0d i=%0d exp=%02x got=%02x addr=%0d",
                                 j, i, gray_of(100+i, 200+j), rd_data, dut.rd_addr);
                end
                rdinc = 1;
                @(posedge clk); #(1);
                rdinc = 0;
            end
        end
        check("K1 框0 1024 字节灰度逐字节正确", bad == 0);

        /* 框1 裁剪窗锚定 (500,300) 32x32，(500..510, 300..306) 77 字节必查 */
        rdsel = 1; rdrst = 1; @(posedge clk); #(1); rdrst = 0; bad = 0;
        for (j = 0; j < 32; j = j + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                @(posedge clk); #(1);
                if (i <= 10 && j <= 6) begin
                    if (rd_data !== gray_of(500+i, 300+j)) bad = bad + 1;
                end
                rdinc = 1;
                @(posedge clk); #(1);
                rdinc = 0;
            end
        end
        check("K3 框1 77 字节灰度正确（其余为帧内像素不查）", bad == 0);

        /* toggle 清零 */
        @(posedge clk); tog = 1; @(posedge clk); tog = 0; #(1);
        check("K5 toggle 后标志清零", cap == {N_BOX{1'b0}});

        $display("============================================");
        if (errors == 0) $display(" ROI_PIXFILL ALL PASSED (%0d checks)", chk);
        else             $display(" ROI_PIXFILL FAILED: %0d/%0d", errors, chk);
        $display("============================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
