/* ============================================================================
 * tb_box_margin —— cvp_box_overlay 外扩/钳位单元回归（detect 组，2026-10-17）
 * ============================================================================
 * 期望值全部由 M 参数推导（M 必须等于被测 BOX_MARGIN）——调外扩参数
 * 只改本文件一处，检查自动跟随。驱动整帧 1280x720 像素流，扫描绿色
 * （24'h00FF00）的包围盒与像素数：
 *   1. 中部框 (100,100)-(200,160)  → (100-M,100-M)-(200+M,160+M)
 *   2. 原点框 (0,0)-(5,5)          → 左/上钳位 (0,0)-(5+M,5+M)
 *   3. 右下角框 (1270,710)-(1279,719) → 右/下钳位到屏边
 *   4. 全 F 空槽                   → 无绿
 *   5. 全 0 退化框                 → 无绿（护栏：锁存倒置坐标）
 *   6. 双真框 + 其余槽全 F         → 合并包围盒 + 两框周长像素数之和
 * 空心校准：像素数精确等于 4*W'+4*H'-16（2px 描边周长公式），
 * 框内多画/漏画一个像素都会 FAIL。
 * 一键跑：vsim -c -do run_box_margin.do
 * ============================================================================
 */
`timescale 1ns/1ps
module tb_box_margin;
    localparam W = 1280, H = 720;
    localparam M = 16;              /* 与被测 BOX_MARGIN 保持一致 */
    localparam [23:0] GREEN = 24'h00FF00;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        valid = 0, sof = 0, toggle = 0;
    reg        test_en = 0, mark_en = 0, mark_valid = 0;
    reg        i_sw1_n = 1;
    reg [23:0] rgb = 24'h123456;
    reg [239:0] boxes = {240{1'b1}};
    wire o_valid, o_sof;
    wire [23:0] o_rgb;

    cvp_box_overlay #(.BOX_MARGIN(M), .DB_CNT(20)) dut (   /* DB_CNT=20 拍快跑 */
        .i_clk(clk), .i_rst_n(rst_n),
        .i_valid(valid), .i_sof(sof), .i_rgb(rgb),
        .o_valid(o_valid), .o_sof(o_sof), .o_rgb(o_rgb),
        .i_box_xy(boxes), .i_box_toggle(toggle),
        .i_test_box(48'h0), .i_test_en(test_en),
        .i_mark_valid(mark_valid), .i_mark_cid(3'd5), .i_mark_en(mark_en),
        .i_sw1_n(i_sw1_n)
    );

    integer gx0, gy0, gx1, gy1, gcnt;   /* 本帧绿色扫描结果 */
    integer px, py, i, errors;

    /* 锁存一组框：slot0=b，其余槽全 F（显式拼接：10.3c 拒绝 {N{X},b} 混写） */
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

    /* SW1 按键激励（低有效）。press 含 <DB_CNT 的抖动 + 稳定按下 + 稳定松开 */
    task press_sw1;
        begin
            i_sw1_n = 0; repeat (4)  @(negedge clk);
            i_sw1_n = 1; repeat (3)  @(negedge clk);   /* 抖动：不得翻转 */
            i_sw1_n = 0; repeat (30) @(negedge clk);   /* 稳定按下 -> 翻转 */
            i_sw1_n = 1; repeat (30) @(negedge clk);   /* 稳定松开 */
        end
    endtask

    task bounce_only;   /* 全程短于 DB_CNT 的抖动：不得翻转 */
        begin
            i_sw1_n = 0; repeat (6)  @(negedge clk);
            i_sw1_n = 1; repeat (6)  @(negedge clk);
            i_sw1_n = 0; repeat (6)  @(negedge clk);
            i_sw1_n = 1; repeat (30) @(negedge clk);
        end
    endtask

    initial begin
        errors = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        /* 1. 中部普通框：四边外扩 M */
        latch_slot0({12'd100, 12'd100, 12'd200, 12'd160});
        run_frame;
        expect_rect(100-M, 100-M, 200+M, 160+M);

        /* 2. 原点边缘框：左/上钳位到 0 */
        latch_slot0({12'd0, 12'd0, 12'd5, 12'd5});
        run_frame;
        expect_rect(0, 0, 5+M, 5+M);

        /* 3. 右下角框：右/下钳到屏边（有效框 x1>x0 保证外扩永不塌点） */
        latch_slot0({12'd1270, 12'd710, 12'd1279, 12'd719});
        run_frame;
        expect_rect(1270-M, 710-M, 1279, 719);

        /* 4. 全 F 空槽：不画 */
        latch_slot0(48'hFFFFFFFFFFFF);
        run_frame;
        expect_no_green("all-F slot");

        /* 5. 全 0 退化框：护栏不画 */
        latch_slot0(48'h0);
        run_frame;
        expect_no_green("all-zero box");

        /* 6. 双真框（slot0/slot1），slot2=全0 走护栏，其余槽全 F：
         *    周长和 = [8*(41+2M)-16] + [8*(101+2M)-16]，角点查合并包围盒 */
        boxes = {48'hFFFFFFFFFFFF, 48'hFFFFFFFFFFFF,
                 48'd0,
                 {12'd500, 12'd300, 12'd600, 12'd400},
                 {12'd300, 12'd200, 12'd340, 12'd240}};
        toggle = 1;
        repeat (4) @(negedge clk);
        toggle = 0;
        run_frame;
        if (gx0 !== 300-M || gy0 !== 200-M || gx1 !== 600+M || gy1 !== 400+M) begin
            errors = errors + 1;
            $display("FAIL: dual-box bbox got (%0d,%0d)-(%0d,%0d), exp (%0d,%0d)-(%0d,%0d)",
                     gx0, gy0, gx1, gy1, 300-M, 200-M, 600+M, 400+M);
        end else
            $display("PASS: dual-box bbox (%0d,%0d)-(%0d,%0d)", gx0, gy0, gx1, gy1);
        if (gcnt !== (8*(41+2*M)-16) + (8*(101+2*M)-16)) begin
            errors = errors + 1;
            $display("FAIL: dual-box total cnt=%0d, exp %0d",
                     gcnt, (8*(41+2*M)-16) + (8*(101+2*M)-16));
        end else
            $display("PASS: dual-box total cnt=%0d", gcnt);

        /* 7. SW1 按下：框消失（r_box_en 翻转，检测语义不在此层） */
        latch_slot0({12'd100, 12'd100, 12'd200, 12'd160});
        run_frame;
        expect_rect(100-M, 100-M, 200+M, 160+M);
        press_sw1;
        run_frame;
        expect_no_green("SW1 pressed");

        /* 8. 再按一次：恢复显示 */
        press_sw1;
        run_frame;
        expect_rect(100-M, 100-M, 200+M, 160+M);

        /* 9. 抖动短于 DB_CNT：不得翻转，框保持可见 */
        bounce_only;
        run_frame;
        expect_rect(100-M, 100-M, 200+M, 160+M);

        if (errors == 0) $display("TB_BOX_MARGIN: ALL 10 CHECKS PASSED (M=%0d)", M);
        else             $display("TB_BOX_MARGIN: %0d FAILURES (M=%0d)", errors, M);
        $finish;
    end
endmodule
