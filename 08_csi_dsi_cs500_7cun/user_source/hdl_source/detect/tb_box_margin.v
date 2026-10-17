/* ============================================================================
 * tb_box_margin —— cvp_box_overlay 外扩/钳位单元回归（detect 组，2026-10-17）
 * ============================================================================
 * 驱动整帧 1280x720 像素流，扫描绿色（24'h00FF00）的包围盒与像素数：
 *   1. 中部框 (100,100)-(200,160)  → 外扩 8 → (92,92)-(208,168)
 *   2. 原点框 (0,0)-(5,5)          → 钳位   → (0,0)-(13,13)
 *   3. 右下角框 (1270,710)-(1279,719) → 钳位 → (1262,702)-(1279,719)
 *   4. 全 F 空槽                   → 无绿
 *   5. 全 0 退化框                 → 无绿（护栏：锁存倒置坐标）
 *   6. 双真框 + 其余槽全 F         → 总周长像素数与合并包围盒
 * 空心校准：像素数精确等于 4*W'+4*H'-16（2px 描边周长公式），
 * 框内多画/漏画一个像素都会 FAIL。
 * 一键跑：vsim -c -do run_box_margin.do
 * ============================================================================
 */
`timescale 1ns/1ps
module tb_box_margin;
    localparam W = 1280, H = 720;
    localparam [23:0] GREEN = 24'h00FF00;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        valid = 0, sof = 0, toggle = 0;
    reg        test_en = 0, mark_en = 0, mark_valid = 0;
    reg [23:0] rgb = 24'h123456;
    reg [239:0] boxes = {240{1'b1}};
    wire o_valid, o_sof;
    wire [23:0] o_rgb;

    cvp_box_overlay dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_valid(valid), .i_sof(sof), .i_rgb(rgb),
        .o_valid(o_valid), .o_sof(o_sof), .o_rgb(o_rgb),
        .i_box_xy(boxes), .i_box_toggle(toggle),
        .i_test_box(48'h0), .i_test_en(test_en),
        .i_mark_valid(mark_valid), .i_mark_cid(3'd5), .i_mark_en(mark_en)
    );

    integer gx0, gy0, gx1, gy1, gcnt;   /* 本帧绿色扫描结果 */
    integer px, py, i, errors;

    /* 锁存一组框：slot0=b，其余槽全 F */
    task latch_slot0(input [47:0] b);
        begin
            boxes = {48'hFFFFFFFFFFFF, 48'hFFFFFFFFFFFF, 48'hFFFFFFFFFFFF,
                     48'hFFFFFFFFFFFF, b};
            toggle = 1;
            repeat (4) @(negedge clk);
            toggle = 0;
            @(negedge clk);
        end
    endtask

    /* 跑一整帧并扫描绿框 */
    task run_frame;
        begin
            px = 0; py = 0;
            gx0 = 999999; gy0 = 999999; gx1 = -1; gy1 = -1; gcnt = 0;
            @(negedge clk);
            valid = 1; sof = 1;
            for (i = 0; i < W*H; i = i + 1) begin
                @(posedge clk);
                #1;
                if (o_rgb === GREEN) begin
                    gcnt = gcnt + 1;
                    if (px < gx0) gx0 = px;
                    if (py < gy0) gy0 = py;
                    if (px > gx1) gx1 = px;
                    if (py > gy1) gy1 = py;
                end
                @(negedge clk);
                sof = 0;
                px = px + 1;
                if (px == W) begin px = 0; py = py + 1; end
            end
            valid = 0;
        end
    endtask

    /* 期望绿框精确等于 (e_x0,e_y0)-(e_x1,e_y1)，像素数=2px 空心周长 */
    task expect_rect(input integer e_x0, e_y0, e_x1, e_y1);
        integer cexp;
        begin
            cexp = 4*(e_x1-e_x0+1) + 4*(e_y1-e_y0+1) - 16;
            if (gx0 !== e_x0 || gy0 !== e_y0 || gx1 !== e_x1 || gy1 !== e_y1 ||
                gcnt !== cexp) begin
                errors = errors + 1;
                $display("FAIL: got (%0d,%0d)-(%0d,%0d) cnt=%0d, exp (%0d,%0d)-(%0d,%0d) cnt=%0d",
                         gx0, gy0, gx1, gy1, gcnt, e_x0, e_y0, e_x1, e_y1, cexp);
            end else
                $display("PASS: box (%0d,%0d)-(%0d,%0d) cnt=%0d", gx0, gy0, gx1, gy1, gcnt);
        end
    endtask

    /* 期望无任何绿 */
    task expect_no_green(input [127:0] name);
        begin
            if (gcnt !== 0) begin
                errors = errors + 1;
                $display("FAIL %0s: got %0d green px, exp 0", name, gcnt);
            end else
                $display("PASS: no green (%0s)", name);
        end
    endtask

    initial begin
        errors = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        /* 1. 中部普通框：外扩 8 */
        latch_slot0({12'd100, 12'd100, 12'd200, 12'd160});
        run_frame;
        expect_rect(92, 92, 208, 168);

        /* 2. 原点边缘框：左/上钳位到 0 */
        latch_slot0({12'd0, 12'd0, 12'd5, 12'd5});
        run_frame;
        expect_rect(0, 0, 13, 13);

        /* 3. 右下角框：右/下钳位到屏边 */
        latch_slot0({12'd1270, 12'd710, 12'd1279, 12'd719});
        run_frame;
        expect_rect(1262, 702, 1279, 719);

        /* 4. 全 F 空槽：不画 */
        latch_slot0(48'hFFFFFFFFFFFF);
        run_frame;
        expect_no_green("all-F slot");

        /* 5. 全 0 退化框：护栏不画 */
        latch_slot0(48'h0);
        run_frame;
        expect_no_green("all-zero box");

        /* 6. 双真框（slot0/slot1），其余槽全 F：
         *    (300,200)-(340,240) → (292,192)-(348,248) 周长 4*57+4*57-16=440
         *    (500,300)-(600,400) → (492,292)-(608,408) 周长 4*117+4*117-16=920 */
        boxes = {48'hFFFFFFFFFFFF, 48'hFFFFFFFFFFFF,
                 48'd0,
                 {12'd500, 12'd300, 12'd600, 12'd400},
                 {12'd300, 12'd200, 12'd340, 12'd240}};
        toggle = 1;
        repeat (4) @(negedge clk);
        toggle = 0;
        run_frame;
        /* 双框：包围盒只查角点（周长公式只适用单实心矩形）；总像素数单查 */
        if (gx0 !== 292 || gy0 !== 192 || gx1 !== 608 || gy1 !== 408) begin
            errors = errors + 1;
            $display("FAIL: dual-box bbox got (%0d,%0d)-(%0d,%0d), exp (292,192)-(608,408)",
                     gx0, gy0, gx1, gy1);
        end else
            $display("PASS: dual-box bbox (292,192)-(608,408)");
        if (gcnt !== 440 + 920) begin
            errors = errors + 1;
            $display("FAIL: dual-box total cnt=%0d, exp 1360", gcnt);
        end else
            $display("PASS: dual-box total cnt=1360");

        if (errors == 0) $display("TB_BOX_MARGIN: ALL 7 CHECKS PASSED");
        else             $display("TB_BOX_MARGIN: %0d FAILURES", errors);
        $finish;
    end
endmodule
