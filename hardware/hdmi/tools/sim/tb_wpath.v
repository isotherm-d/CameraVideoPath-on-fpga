`timescale 1ns / 1ps
/*=============================================================================
 * tb_wpath —— uidbuf 写通路专项仿真(冻结 bug 猎捕)
 *
 *   行为级像素源(模拟重组器输出契约: FS 脉冲 → 921600 px @1字/拍, 帧背靠背)
 *     → uidbuf(W 写侧, 含 W_REQ 两级同步补丁) → 假想 FDMA 写控制器
 *       (理想 DDR: wareq 上升 → 连发 fdma_wsize 拍 wvalid 排空)
 *
 * 监视:
 *   1. empty_flag 在 fdma_wvalid 期间拉高 = FIFO 被读穿(过读, 指针损坏风险)
 *   2. W_MS 卡在 S_DATA1 且 W_REQ 长期为 0 = 写状态机饿死(画面冻结的直接机制)
 *   3. 每帧 wvalid 计数 = 921600(帧写完整); FS 周期稳定性
 *===========================================================================*/
`timescale 1ns / 1ps
module tb_wpath;

    localparam real    T150      = 6.667;             // ui_clk/fdma_clk 150M
    localparam real    T125      = 8.0;               // W 写域 125M
    localparam integer PX_PER_FRAME = 921600;           // 1280*720
    localparam integer BURST       = 512;               // 假想写控制器突发长度
    localparam integer NFRAMES     = 30;
    localparam integer FR_CYC      = 4_160_000;    // 帧周期 33.3ms@8ns(真机 30fps), 与 60Hz 场 2:1

    reg clk150 = 0;
    reg clk125 = 0;
    reg clk75  = 0;
    always #(T150/2.0) clk150 = ~clk150;
    always #(T125/2.0) clk125 = ~clk125;
    always #(T125*2.0/3.0) clk75 = ~clk75;              // 75M ≈ 125M*(2/3)

    reg rstn = 0;
    initial begin
        repeat (20) @(posedge clk150);
        rstn = 1;
    end

    /* ---------------- 行为级像素源(125M 写域, 模拟重组器输出契约) -------------
     * 每帧: FS 拉高 64 拍 → 空闲 512 拍(uidbuf 复位窗) → 921600 px @1字/拍。
     * 帧周期 = FR_CYC 个写域时钟, 帧背靠背。 */
    reg        src_fs = 0;
    reg        src_de  = 0;
    reg [23:0] src_rgb = 0;
    integer    fi = 0, px = 0, gap = 0;
    integer    fs_start = 0;

    initial begin
        wait (rstn);
        @(posedge clk125);
        forever begin
            /* FS 脉冲 64 拍 */
            src_fs <= 1'b1;
            repeat (64) @(posedge clk125);
            src_fs <= 1'b0;
            fs_start = $time / 1.0;
            /* 空闲 512 拍(uidbuf 复位窗) */
            repeat (512) @(posedge clk125);
            /* 921600 像素 @1字/拍 */
            for (px = 0; px < PX_PER_FRAME; px = px + 1) begin
                src_de  <= 1'b1;
                src_rgb <= {4'b0, fi[3:0], px[15:8], px[7:0]}; // R=帧号标签, G/B=位置递增
                @(posedge clk125);
            end
            src_de <= 1'b0;
            @(posedge clk125);
            /* 帧尾空隙 */
            gap = FR_CYC - PX_PER_FRAME - 512 - 64 - 1;
            if (gap < 1) gap = 1;
            repeat (gap) @(posedge clk125);
            fi = fi + 1;
            if (fi >= NFRAMES + 2) begin
                while (1) @(posedge clk125);   // 源预算用尽后停摆(仅停止发帧)
            end
        end
    end

    /* 安路仿真库全局复位模型(EG_LOGIC_FIFO 内部引用 glbl.gsrn) */
    glbl glbl();

    /* ---------------- DUT: uidbuf ---------------- */
    wire       fs_cap_w;   /* 未用 */
    wire [7:0] W_sync_cnt;
    wire       R_empty_w;
    wire [7:0] R_sync_w;
    wire [23:0] R_data_w;
    wire [1:0] fmda_wbuf_w, fmda_rbuf_w;
    wire       fdma_wirq_w, fdma_rirq_w;

    wire [23:0] fdma_waddr_w;
    wire        fdma_wareq_w, fdma_wbusy_w, fdma_wvalid_w;
    wire [15:0] fdma_wsize_w;
    wire [31:0] fdma_wdata_w;
    wire [23:0] fdma_raddr_w;
    wire        fdma_rareq_w, fdma_rbusy_w, fdma_rvalid_w;
    wire [15:0] fdma_rsize_w;
    wire [31:0] fdma_rdata_w;
    reg         R_FS_i = 0;
    reg         rden75 = 0;

    uidbuf #(
        .VIDEO_ENABLE(1), .ENABLE_WRITE(1), .ENABLE_READ(1),
        .AXI_DATA_WIDTH(32), .AXI_ADDR_WIDTH(24),
        .W_BUFDEPTH(2048), .W_DATAWIDTH(32), .W_BASEADDR(0), .W_DSIZEBITS(22),
        .W_XSIZE(1280), .W_YSIZE(720), .W_BUFSIZE(3),
        .R_BUFDEPTH(2048), .R_DATAWIDTH(32), .R_BASEADDR(0), .R_DSIZEBITS(22),
        .R_XSIZE(1280), .R_YSIZE(720), .R_BUFSIZE(3)
    ) u_uidbuf (
        .ui_clk   (clk150), .ui_rstn (rstn),
        .W_wclk_i (clk125), .W_FS_i  (src_fs), .W_wren_i (src_de),
        .W_data_i ({8'h00, src_rgb}),
        .W_sync_cnt_o (W_sync_cnt), .W_buf_i (W_sync_cnt), .W_full (),
        .R_rclk_i (clk75),  .R_FS_i  (R_FS_i),  .R_rden_i (rden75),
        .R_data_o (R_data_w), .R_sync_cnt_o (R_sync_w), .R_buf_i (R_sync_w),
        .R_empty  (R_empty_w),
        .fdma_waddr (fdma_waddr_w), .fdma_wareq (fdma_wareq_w),
        .fdma_wsize (fdma_wsize_w), .fdma_wbusy (fdma_wbusy_w),
        .fdma_wdata (fdma_wdata_w), .fdma_wvalid(fdma_wvalid_w),
        .fmda_wbuf  (fmda_wbuf_w),  .fdma_wirq  (fdma_wirq_w),
        .fdma_raddr (fdma_raddr_w), .fdma_rareq (fdma_rareq_w),
        .fdma_rsize (fdma_rsize_w), .fdma_rbusy (fdma_rbusy_w),
        .fdma_rdata (fdma_rdata_w), .fdma_rvalid(fdma_rvalid_w),
        .fmda_rbuf  (fmda_rbuf_w),  .fdma_rirq  (fdma_rirq_w)
    );

    /* ---------------- 假想 FDMA 写控制器(理想 DDR): wareq → 连发 BURST 拍 ------- */
    reg        wbusy = 0;
    reg        wv = 0;
    integer    bcnt = 0;
    always @(posedge clk150) begin
        if (!rstn) begin
            wbusy <= 0; wv <= 0; bcnt <= 0;
        end else if (fdma_wareq_w && !wbusy && !wv) begin
            wbusy <= 1'b1;
            wv    <= 1'b1;
            bcnt  <= 1;
        end else if (wbusy) begin
            if (bcnt >= fdma_wsize_w - 1) begin
                wv <= 1'b0; wbusy <= 1'b0; bcnt <= 0;
            end else begin
                wv <= 1'b1; bcnt <= bcnt + 1;
            end
        end else begin
            wv <= 1'b0;
        end
    end
    assign fdma_wbusy_w  = wbusy;
    assign fdma_wvalid_w = wv;

    /* ---------------- 假想 DDR 内存(W 写入 / R 读出, 端到端一致性) ---------- */
    reg [31:0] vram [0:3_000_000];                  // 12MB = 3 缓冲
    integer wbase = 0, wcnt = 0, rbase = 0, rcnt = 0, rlat = 0;
    reg       rv = 0;
    /* W: wareq 锁存突发基址, wvalid 逐字写入 */
    always @(posedge clk150) begin
        if (!rstn) begin wbase <= 0; wcnt <= 0; end
        else if (fdma_wareq_w) begin wbase <= fdma_waddr_w[23:2]; wcnt <= 0; end
        else if (fdma_wvalid_w) begin
            vram[wbase + wcnt] <= fdma_wdata_w;
            wcnt <= wcnt + 1;
        end
    end
    /* R: rareq → 延迟 → rvalid × rsize, 从 vram 读回 */
    always @(posedge clk150) begin
        if (!rstn) begin rv <= 0; rcnt <= 0; rlat <= 0; end
        else if (fdma_rareq_w && !rv && !fdma_rbusy_w) begin
            rbase <= fdma_raddr_w[23:2]; rlat <= 16; rv <= 1; rcnt <= 0;
        end else if (rv) begin
            if (rlat > 0) rlat <= rlat - 1;
            else begin
                fdma_rdata_w <= vram[rbase + rcnt];
                fdma_rvalid_w <= 1'b1;
                rcnt <= rcnt + 1;
                if (rcnt >= fdma_rsize_w - 1) begin rv <= 1'b0; fdma_rvalid_w <= 1'b0; end
            end
        end else begin
            fdma_rvalid_w <= 1'b0;
        end
    end

    /* 显示消费模型: 75M 域连续读 d2f(R_rden=1), 监视撕裂(标签突变)/读空(停增) */
    reg [23:0] pv = 24'hxx, ppv = 24'hxx;
    integer    field_px = 0, tears = 0, underruns = 0, field_tag = 9, last_full_field = 0;
    reg        tag_err = 0;
    /* R_FS: 每 1_250_000 clk75(16.7ms 场头), 脉宽 64 拍 */
    integer vfs_cnt = 0;
    always @(posedge clk75) begin
        if (!rstn) begin
            vfs_cnt <= 0; R_FS_i <= 1'b0;
        end else begin
            vfs_cnt <= vfs_cnt + 1;
            if (vfs_cnt >= 1_250_000) begin vfs_cnt <= 0; R_FS_i <= 1'b1; end
            else if (vfs_cnt == 63) R_FS_i <= 1'b0;
        end
    end
    always @(posedge clk75) rden75 <= rstn;
    always @(posedge clk75) begin
        if (!rstn) begin
            field_px <= 0;
        end else begin
            if (R_FS_i) begin
                if (field_px != 0 && field_px != PX_PER_FRAME)
                    $display("[TEAR] t=%0t 场内像素数=%0d (期望 %0d)", $time/1000, field_px, PX_PER_FRAME);
                field_px <= 0;
            end
            if (R_rden_i && !R_empty_w) begin
                pv <= R_data_w;
                field_px <= field_px + 1;
            end else if (R_rden_i) begin
                underruns = underruns + 1;
                if (underruns <= 5) $display("[MON] t=%0t d2f 读空(显示供给不足)", $time/1000);
            end
        end
    end
    always @(posedge clk75) begin
        if (rstn && R_rden_i && R_FS_i == 1'b0) begin
            /* 标签突变 = 新旧帧在同一场内拼接(撕裂) */
            if (field_px > 1 && pv[19:16] != R_data_w[23:20] && R_data_w[23:20] < 10) begin
                tears = tears + 1;
                if (tears <= 8)
                    $display("[TEAR] t=%0t 帧标签突变: %0d → %0d (场内第 %0d px)",
                             $time/1000, pv[19:16], R_data_w[23:20], field_px);
            end
        end
    end

    /* ---------------- 监视器 ---------------- */
    integer wvalid_cnt = 0, frames_done = 0, overread = 0, stall_ms = 0;
    integer last_fcnt = 0;
    reg     fs_prev = 0;
    wire    fs_rise = src_fs & ~fs_prev;
    always @(posedge clk125) fs_prev <= src_fs;

    /* 过读监视: wvalid 期间 empty_flag 拉高 */
    always @(posedge clk150) begin
        if (rstn && fdma_wvalid_w && u_uidbuf.FDMA_WRITE_ENABLE.empty_flag) begin
            overread = overread + 1;
            if (overread <= 5)
                $display("[MON] t=%0t OVER-READ: empty_flag 在写突发中拉高 (第%0d次)", $time, overread);
        end
    end

    /* 每帧统计(FS 上升沿): 该帧 wvalid 计数 */
    integer wv_frame = 0;
    always @(posedge clk150) begin
        if (rstn) begin
            if (fdma_wvalid_w) wv_frame = wv_frame + 1;
            if (fs_rise) begin
                $display("[FRAME] 第%0d帧输出完成: wvalid=%0d (期望 %0d)", frames_done, wv_frame, PX_PER_FRAME);
                wv_frame = 0;
                frames_done = frames_done + 1;
            end
        end
    end

    /* 卡死看门狗: W_MS==S_DATA1(2) 且 W_REQ==0 且 staging 空, 持续 5e6 ns */
    reg [63:0] stall_start = 0;
    /* 饥饿监视: W_MS 停在 S_DATA1 等 W_REQ, 且 f2d FIFO 空而像素源仍在写 */
    always @(posedge clk150) begin
        if (!rstn) stall_start <= 0;
        else if (u_uidbuf.FDMA_WRITE_ENABLE.W_MS == 2'd2 && u_uidbuf.FDMA_WRITE_ENABLE.W_REQ == 1'b0 &&
                 u_uidbuf.FDMA_WRITE_ENABLE.empty_flag == 1'b1 && src_de) begin
            if (stall_start == 0) stall_start = $time;
            else if ($time - stall_start > 2_000_000) begin
                $display("[MON] t=%0t *** W写状态机饿死 2us+: S_DATA1 等W_REQ, f2d空, 像素源活跃", $time);
                $display("[MON] afull_raw=%b w_req_sync=%b —— 若 afull=0 而 FIFO 实际有数据, 即同步延迟吞请求",
                         u_uidbuf.FDMA_WRITE_ENABLE.w_afull_raw, u_uidbuf.FDMA_WRITE_ENABLE.w_req_sync);
                stall_start = 0;
            end
        end else begin
            stall_start = 0;
        end
    end

    /* 时钟周期权威测量 */
    real t1 = 0, t2 = 0;
    integer meas = 0;
    always @(posedge clk125) begin
        if (meas == 0) t1 = $realtime;
        else if (meas == 1) begin
            t2 = $realtime;
            $display("[CLK] clk125 周期 = %0.3f (timeunits), sim precision 见 timescale", t2 - t1);
            meas = 2;
        end else if (meas == 2) meas = 3;
    end

    /* 周期状态打印: 每 300us */
    always #(300_000) begin
        $display("[ST] t=%0t W_MS=%0d W_REQ=%b afull=%b f2dEmpty=%b srcFS=%b srcDE=%b wvalidCnt=%0d",
                 $time, u_uidbuf.FDMA_WRITE_ENABLE.W_MS,
                 u_uidbuf.FDMA_WRITE_ENABLE.W_REQ,
                 u_uidbuf.FDMA_WRITE_ENABLE.w_afull_raw,
                 u_uidbuf.FDMA_WRITE_ENABLE.empty_flag,
                 src_fs, src_de, wv_frame);
    end

    initial begin
        #300_000_000;                                // 300ms
        $display("[TB] ===== 结果 =====");
        $display("[TB] 完成帧数(FS)=%0d, 过读事件=%0d", frames_done, overread);
        if (overread == 0)
            $display("[TB] *** W 通路健康: 无过读, 无饥饿报告 ***");
        else
            $display("[TB] *** 发现过读 —— FIFO 指针损坏风险成立 ***");
        $finish;
    end

endmodule
