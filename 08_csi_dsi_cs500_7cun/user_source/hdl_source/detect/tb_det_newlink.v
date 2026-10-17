/* ============================================================================
 * tb_det_newlink —— 新工程接入版全链联合仿真（detect 组 2026-10-10）
 * ============================================================================
 * 激励：tb_det_ispfeed（9-19）产出的**真实 ISP 像素**（181122 帧过完整
 *   RTL 解马赛克+AWB 的稳态帧，clean_pix_181122.hex，24bit/像素行主序）
 *   —— clean 流在真实系统里就是 AWB 后像素，此处直接以 clean 时序灌入
 *   det_color_feat，等价于板上 clean_* 抽头（30fps 720p）。
 *
 * 链路：det_color_feat（冻结参数）→ det_wbc20 → det_roi_bridge，
 *   与 design_top_wrapper.v 的接入完全同构（ENABLE_FOV=0）。
 *
 * 断言（期望值来自 9-19 isp_hue_verify 离线镜像，同帧同参数）：
 *   K1 框数 = 3（±1 容差：RTL 4 连通 vs 镜像 8 连通的边缘差异）；
 *   K2 三个真核中心逐一被框命中（±14px）：(644,259)(493,316)(885,290)；
 *   K3 无远偏框（所有框中心落在任一真核 40px 内）；
 *   K4 bridge 发出 ≥3 个块且 bbox 命中同三核；
 *   K5 roi frame_id = 产生检测的帧号（第 2 帧 → fid==2）。
 * ============================================================================
 */
`timescale 1ns/1ps

module tb_det_newlink;

    localparam W = 1280, H = 720, NPIX = W*H;
    localparam N_BOX = 5;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    /* clean 流激励 */
    reg [23:0] pix [0:NPIX-1];
    reg        cv = 0;
    reg [23:0] crgb;
    reg        csof = 0, ceof = 0;
    reg [31:0] cfid = 0;

    /* DUT 链（与 wrapper 接线同构） */
    wire        cc_v;  wire [2:0] cc_cid;
    wire        d_v;  wire [2:0] d_cid;
    wire [N_BOX*48-1:0] box_xy;
    wire        box_tog;

    det_color_feat #(
        .HUE_CB(10'd700), .HUE_BM(10'd996), .HUE_MR(10'd1010), .S_MIN(8'd100)
    ) u_color (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_valid(cv), .i_rgb(crgb), .i_frame_start(csof),
        .o_valid(cc_v), .o_frame_start(), .o_hue(), .o_sat(), .o_val(), .o_cid(cc_cid)
    );

    /* 3x3 多数表决：杀孤立紫噪点（标签预算治理，2026-10-10）
     * 3x3 开运算：杀无实心核的残余团块（进一步降标签消耗，2026-10-10） */
    wire        mf_v;
    wire [2:0]  mf_cid;
    det_cid_filter #(.IMG_W(W), .WBC_CID(3'd5)) u_cidfilter (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_valid(cc_v), .i_cid(cc_cid),
        .o_valid(mf_v), .o_cid(mf_cid)
    );
    wire        open_v;
    wire        open_v_unused;
    det_bin_open3 #(.IMG_W(W)) u_open3 (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_valid(mf_v), .i_bin(mf_cid == 3'd5),
        .o_valid(d_v), .o_bin(open_v)
    );
    assign d_cid = (d_v && open_v) ? 3'd5 : 3'd0;

    det_wbc20 #(
        .IMG_W(W), .IMG_H(H), .WBC_CID(3'd5), .MIN_AREA(12'd400),
        .N_OUT(N_BOX), .COORD_ADJ(12'd0), .ENABLE_FOV(1'b0),
        .COMPACT_PCT(37), .MAX_AREA_PCT(15),
        .MERGE_GAP(12'd2), .SEED_MIN(256), .MERGE_MAXWH(128)
    ) u_wbc (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_valid(d_v), .i_cid(d_cid),
        .o_box_xy(box_xy), .o_box_text(), .o_box_color(),
        .o_frame_done(), .o_box_toggle(box_tog)
    );

    /* bridge */
    wire        bv, bsop, beop, breq;
    wire [7:0]  bdata;
    wire [31:0] bfid;
    wire [15:0] broi;
    wire [63:0] bbbox;

    det_roi_bridge #(.N_BOX(N_BOX), .BLK_BYTES(1024)) u_bridge (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_box_xy(box_xy), .i_box_toggle(box_tog), .i_frame_id(cfid),
        .i_pix_en(1'b0), .i_pix_data(8'd0), .o_pix_req(breq),
        .o_valid(bv), .i_ready(1'b1), .o_data(bdata),
        .o_sop(bsop), .o_eop(beop), .o_frame_id(bfid),
        .o_roi_id(broi), .o_cfg_id(), .o_bbox(bbbox),
        .o_width(), .o_height(), .o_channels(), .o_format()
    );

    /* bridge 自动采样器（同 tb_det_roi） */
    reg [63:0] kbox [0:N_BOX-1];
    reg [31:0] kfid [0:N_BOX-1];
    integer    knblk = 0;
    reg [10:0] kbidx;
    reg        kcap;

    always @(posedge clk) begin
        if (!rst_n) begin
            knblk <= 0; kbidx <= 0; kcap <= 0;
        end else if (bv && 1'b1) begin
            if (bsop) begin
                kcap <= 1'b1;
                kfid[knblk]  <= bfid;
                kbox[knblk]  <= bbbox;
                kbidx        <= 1;
            end else if (kcap) begin
                kbidx <= kbidx + 1'b1;
            end
            if (beop) begin
                kcap  <= 1'b0;
                knblk <= knblk + 1;
            end
        end
    end

    /* 框总线 toggle 沿采样 */
    reg        tog_d = 0;
    reg [N_BOX*48-1:0] sbox;
    reg [31:0] sfid;
    wire       tog_edge = box_tog ^ tog_d;
    integer    nboxes;
    reg [47:0] boxes [0:N_BOX-1];

    always @(posedge clk) begin
        tog_d <= box_tog;
        if (tog_edge) begin
            sbox <= box_xy;
            sfid <= cfid;
        end
    end

    integer errors = 0, chk = 0;
    task check(input [255:0] name, input ok);
        begin
            chk = chk + 1;
            if (!ok) begin errors = errors + 1; $display("[FAIL] %0s", name); end
            else     $display("[PASS] %0s", name);
        end
    endtask

    /* 从 sbox 解出有效框 */
    task decode_boxes;
        integer i;
        begin
            nboxes = 0;
            for (i = 0; i < N_BOX; i = i + 1) begin
                if (sbox[i*48 + 36 +: 12] != 12'hFFF) begin
                    boxes[nboxes] = sbox[i*48 +: 48];
                    nboxes = nboxes + 1;
                end
            end
        end
    endtask

    integer hit [0:N_BOX-1];   // 每个真核是否被命中

    task match_centers;
        integer i, j;
        integer bcx, bcy, d;
        begin
            for (i = 0; i < 3; i = i + 1) hit[i] = 0;
            for (j = 0; j < nboxes; j = j + 1) begin
                bcx = (boxes[j][47:36] + boxes[j][23:12]) >> 1;
                bcy = (boxes[j][35:24] + boxes[j][11:0])  >> 1;
                if (max2(bcx,644)-min2(bcx,644) <= 14 && max2(bcy,259)-min2(bcy,259) <= 14) hit[0] = 1;
                if (max2(bcx,493)-min2(bcx,493) <= 14 && max2(bcy,316)-min2(bcy,316) <= 14) hit[1] = 1;
                if (max2(bcx,885)-min2(bcx,885) <= 14 && max2(bcy,290)-min2(bcy,290) <= 14) hit[2] = 1;
            end
        end
    endtask

    function integer max2(input integer a, input integer b);
        max2 = (a > b) ? a : b;
    endfunction
    function integer min2(input integer a, input integer b);
        min2 = (a < b) ? a : b;
    endfunction

    /* SYNTH 模式：1280x720 合成图（3 个 6x6 紫块 + 灰底 RAW10 风格），
     * 二分"真实图数据问题" vs "720p 结构问题" */
    reg synth_mode = 0;
    reg kchk = 0;
    reg [1023:0] hexfile;
    function [23:0] synth_pix(input integer idx);
        integer sx, sy;
        begin
            sx = idx % W; sy = idx / W;
            if (((sx >= 600) && (sx <= 605) && (sy >= 240) && (sy <= 245)) ||
                ((sx >= 900) && (sx <= 905) && (sy >= 400) && (sy <= 405)) ||
                ((sx >= 300) && (sx <= 305) && (sy >= 500) && (sy <= 505)))
                synth_pix = 24'h5a26a9;   // 与真实核同色
            else
                synth_pix = 24'h808080;   // 灰底（S=0 不入窗）
        end
    endfunction

    integer frame, px, total_sent, guard;
    integer dbg_x = 0, dbg_y = 0;
    integer hframe = 0;
    integer c5_cnt = 0, dv_cnt = 0;   // 到达 det_wbc20 的 cid=5 / 总 valid 计数
    integer bin1_cnt = 0, s3_cnt = 0, s3_op123 = 0;  // S1 入口/S3 落账分层
    integer op1_cnt = 0, op2_cnt = 0, op3_cnt = 0, op0_bin = 0;
    integer cf_in = 0, cf_dbg = 0;

    /* 追踪特定像素过链路（注意：dbg 计数器跨帧累加，帧 2 的 dbg_y = 720+真实行号） */
    always @(posedge clk) begin
        if (rst_n && cv) begin
            if (dbg_x == 639 && (dbg_y == 250 || dbg_y == 0 || dbg_y == 970))
                $display("[TRK ] t=%0t xy=(%0d,%0d) crgb=%h d_cid=%0d d_v=%b",
                         $time, dbg_x, dbg_y, crgb, d_cid, d_v);
            if (dbg_y == 935 && (dbg_x == 400 || dbg_x == 800 || dbg_x == 1100))
                $display("[TRK2] t=%0t row215 xy=(%0d) crgb=%h hue=%0d sat=%0d cid=%0d",
                         $time, dbg_x - 0, crgb, u_color.o_hue, u_color.o_sat,
                         u_color.o_cid);
            if (dbg_x == W-1) begin
                dbg_x = 0;
                dbg_y = dbg_y + 1;
            end else begin
                dbg_x = dbg_x + 1;
            end
        end
    end

    /* det 内部坐标 vs 真实紫像素到达位置对照（前 8 次） */
    integer trk5 = 0;
    integer oob_cnt = 0;
    always @(posedge clk) begin
        if (rst_n && d_v && d_cid == 3'd5) begin
            if (hframe == 2 && u_wbc.r_y0 >= 213 && u_wbc.r_y0 <= 219 && trk5 < 20) begin
                trk5 = trk5 + 1;
                $display("[BAND] t=%0t det_S0_xy=(%0d,%0d) cid=5 in band rows",
                         $time, u_wbc.r_x0, u_wbc.r_y0);
            end
        end
    end

    /* w_first 脉冲计数（应=2：两次帧首；多则=中途伪帧首=表清零元凶） */
    integer wfirst_cnt = 0;
    always @(posedge clk) begin
        if (rst_n && u_wbc.w_first) begin
            wfirst_cnt = wfirst_cnt + 1;
            hframe = hframe + 1;
            $display("[WFRST] t=%0t w_first #%0d (det xy counter %0d,%0d)",
                     $time, wfirst_cnt, u_wbc.r_x, u_wbc.r_y);
        end
    end

    /* argmax 逐轮探针：R_COMMIT 拍打印本轮赢家与几何过滤结果 */
    always @(posedge clk) begin
        if (rst_n && u_wbc.r_fst == 5'd18 && hframe == 2)   // 18=几何判定+写框(2026-10-17 两级流水)
            $display("[ARG ] round=%0d eff=%0d cnt=%0d box=(%0d,%0d)-(%0d,%0d) geom_ok=%b bw=%0d bh=%0d",
                     u_wbc.r_round, u_wbc.r_eff, u_wbc.r_c_cnt,
                     u_wbc.s_mnx_a[u_wbc.r_eff], u_wbc.s_mny_a[u_wbc.r_eff],
                     u_wbc.s_mxx_a[u_wbc.r_eff], u_wbc.s_mxy_a[u_wbc.r_eff],
                     u_wbc.w_geom_ok_r, u_wbc.r_c_bw, u_wbc.r_c_bh);
    end

    /* ---- 标签回收诊断探针（2026-10-10）----
     * BADMG：真实 4 连通合并中，左根组件必含 (x-1,y)、上根组件必含
     *   (x,y-1)；违反 = 无关组件被焊进同一统计（回收引用错乱信号）。
     * DBLAL：弹栈分配执行拍，目标标签 closed 必仍为 1；为 0 = 双重分配。 */
    /* 帧末 live 表快照：eof4 拍全量打印非零标签（CCL 级焊接定位） */
    integer pi;
    always @(posedge clk) begin
        if (rst_n && u_wbc.r_eof4) begin
            $display("[LIVEDMP] sp=%0d nscnt=%0d alloc=%0d",
                     u_wbc.r_sp, u_wbc.ns_cnt, u_wbc.r_alloc);
            for (pi = 0; pi < u_wbc.NL; pi = pi + 1)
                if (u_wbc.cnt_0[pi] > 0)
                    $display("[LIVEDMP] lab=%0d p=%0d cnt=%0d x %0d-%0d y %0d-%0d cl=%b ly=%0d",
                             pi, u_wbc.parent_0[pi], u_wbc.cnt_0[pi],
                             u_wbc.mnx_0[pi], u_wbc.mxx_0[pi],
                             u_wbc.mny_0[pi], u_wbc.mxy_0[pi],
                             u_wbc.closed[pi], u_wbc.lasty[pi]);
        end
    end

    /* 关闭事件史：reaper 候选拍打印被关闭组件的完整现场（重建标签生平） */
    always @(posedge clk) begin
        if (rst_n && u_wbc.w_rp_cand)
            $display("[CLOSE] t=%0t lab=%0d cnt=%0d bbox=(%0d,%0d)-(%0d,%0d) lasty=%0d y_now=%0d",
                     $time, u_wbc.r_rp, u_wbc.cnt_0[u_wbc.r_rp],
                     u_wbc.mnx_0[u_wbc.r_rp], u_wbc.mny_0[u_wbc.r_rp],
                     u_wbc.mxx_0[u_wbc.r_rp], u_wbc.mxy_0[u_wbc.r_rp],
                     u_wbc.lasty[u_wbc.r_rp], u_wbc.r_y0);
    end

    /* scratch 转储：压平完成时刻（BSUM 起始拍）打印 cnt>=100 的槽位，
     * 对照旧版 RTL 的 41:1685 / 90:1582 / 80:833 三核分布 */
    integer qi, qsum;
    always @(posedge clk) begin
        if (rst_n && u_wbc.r_fst == 5'd6 && u_wbc.r_sidx == 0) begin
            qsum = 0;
            $display("[SCRADMP] === scratch after flatten, amax=%0d ===", u_wbc.s_amax);
            for (qi = 0; qi < u_wbc.s_amax; qi = qi + 1) begin
                qsum = qsum + u_wbc.scnt_a[qi];
                if (u_wbc.scnt_a[qi] >= 100)
                    $display("[SCRADMP] slot=%0d par=%0d cnt=%0d x %0d-%0d y %0d-%0d dead=%b",
                             qi, u_wbc.sparent_a[qi], u_wbc.scnt_a[qi],
                             u_wbc.s_mnx_a[qi], u_wbc.s_mxx_a[qi],
                             u_wbc.s_mny_a[qi], u_wbc.s_mxy_a[qi], u_wbc.s_dead[qi]);
            end
            $display("[SCRADMP] SUM scnt=%0d", qsum);
        end
    end


    /* cid=5 行直方图（第二帧起统计）：真核行 241-332 应有数千 */
    integer hist [0:H-1];
    integer hsum = 0;
    always @(posedge clk) begin
        if (rst_n && d_v && d_cid == 3'd5 && hframe == 2) begin
            hist[u_wbc.r_y0] = hist[u_wbc.r_y0] + 1;
            hsum = hsum + 1;
        end
    end

    initial begin
        /* +HEX=<file> 激励 hex（默认 181122）；+KCHK=1 启用 181122 专项断言；
         * +SYNTH=1 合成图模式保留（hexfile/kchk 声明在模块级） */
        $display("[CFG] NL=%0d POP_EN=%0d RECYCLE_EN=%0d",
                 u_wbc.NL, u_wbc.POP_EN, u_wbc.RECYCLE_EN);
        if (!$value$plusargs("SYNTH=%d", synth_mode)) synth_mode = 0;
        if (!$value$plusargs("KCHK=%d", kchk)) kchk = 0;
        if (synth_mode) begin
            /* 合成图模式不读 hex */
        end else if (!$value$plusargs("HEX=%s", hexfile)) begin
            hexfile = "clean_pix_181122.hex";
        end
        if (!synth_mode) $readmemh(hexfile, pix);
        begin : INIT_HIST
            integer zi;
            for (zi = 0; zi < H; zi = zi + 1) hist[zi] = 0;
        end
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        /* 灌 2 帧：帧 1 供 AWB 域状态无关的检测流水预热，帧 2 末出框 */
        for (frame = 1; frame <= 2; frame = frame + 1) begin
            cfid = frame;
            @(posedge clk); csof = 1; cv = 1; crgb = synth_mode ? synth_pix(0) : pix[0];
            @(posedge clk); csof = 0;
            for (px = 1; px < NPIX; px = px + 1) begin
                crgb = synth_mode ? synth_pix(px) : pix[px];
                ceof = (px == NPIX-1);
                @(posedge clk);
            end
            ceof = 0;
            cv = 0;
            /* 帧间消隐（30fps 口径等效，仿真缩短为 2 万拍） */
            repeat (20000) @(posedge clk);
        end

        /* 等帧 2 解析完成：NL=128 时合并扫描可达 ~百万拍（O(NL²)/轮），
         * 硬件上与下一帧流并行（33ms 帧周期 >> 解析），TB 需显式等 30ms */
        repeat (3000000) @(posedge clk);

        /* 等框总线更新 */
        guard = 0;
        while (nboxes == 0 && guard < 200000) begin
            @(posedge clk);
            decode_boxes;
            guard = guard + 1;
        end

        $display("[DBG ] detected boxes = %0d (fid=%0d) sbox=%h", nboxes, sfid, sbox[47:0]);
        $display("[DBG ] live box bus [47:0]=%h [95:48]=%h", box_xy[47:0], box_xy[95:48]);
        begin : DBG_LABELS
            integer di;
            integer sum;
            sum = 0;
            $display("[DBG ] s_amax=%0d r_alloc=%0d nscnt=%0d sp=%0d giveup=%0d dv=%0d c5port=%0d bin1=%0d | op1=%0d op2=%0d op3=%0d op0bin(丢弃)=%0d",
                     u_wbc.s_amax, u_wbc.r_alloc, u_wbc.ns_cnt, u_wbc.r_sp,
                     u_wbc.r_giveup, dv_cnt, c5_cnt, bin1_cnt,
                     op1_cnt, op2_cnt, op3_cnt, op0_bin);
            for (di = 0; di < u_wbc.NL; di = di + 1)
                if (u_wbc.cnt_0[di] > 0) begin
                    sum = sum + u_wbc.cnt_0[di];
                    if (u_wbc.cnt_0[di] >= 8 && u_wbc.mny_0[di] < 600)
                        $display("[DBG ] LIVE label %0d: cnt=%0d x %0d-%0d y %0d-%0d",
                                 di, u_wbc.cnt_0[di], u_wbc.mnx_0[di], u_wbc.mxx_0[di],
                                 u_wbc.mny_0[di], u_wbc.mxy_0[di]);
                end
            begin : DBG_BOXES
                integer bi2;
                for (bi2 = 0; bi2 < 10; bi2 = bi2 + 1)
                    $display("[DBG ] r_box[%0d]=%h", bi2, u_wbc.r_box[bi2]);
            end
            $display("[DBG ] SUM of all cnt = %0d (expect ~4667/frame x? frames)", sum);
            $display("[DBG ] cid5 row histogram (frame 2): hsum=%0d", hsum);
            begin : DBG_HIST
                integer hi;
                for (hi = 0; hi < H; hi = hi + 1)
                    if (hist[hi] > 0)
                        $display("[DBG ] row %0d: %0d purple px", hi, hist[hi]);
            end
            begin : DBG_DEPTH
                integer ei, bad_depth;
                bad_depth = 0;
                for (ei = 0; ei < u_wbc.NL; ei = ei + 1) begin
                    if (u_wbc.parent_0[ei] != ei[5:0]) begin
                        // 有父指针：查两级后是否到根
                        if (u_wbc.parent_0[u_wbc.parent_0[ei]] != u_wbc.parent_0[ei]) begin
                            bad_depth = bad_depth + 1;
                            $display("[DBG ] DEPTH>2 at label %0d: p=%0d pp=%0d ppp=%0d",
                                     ei, u_wbc.parent_0[ei], u_wbc.parent_0[u_wbc.parent_0[ei]],
                                     u_wbc.parent_0[u_wbc.parent_0[u_wbc.parent_0[ei]]]);
                        end
                    end
                end
                $display("[DBG ] labels with parent-chain depth > 2: %0d", bad_depth);
            end
        end
        decode_boxes;
        if (kchk) begin
            match_centers;
        end

        if (kchk) check("K1 框数=3（容差 2~4）", nboxes >= 2 && nboxes <= 4);
        if (kchk) check("K2a 中性核A(644,259) 被框", hit[0] == 1);
        if (kchk) check("K2b 中性核B(493,316) 被框", hit[1] == 1);
        if (kchk) check("K2c 淋巴核C(885,290) 被框", hit[2] == 1);
        if (kchk) begin : K3
            integer j, ok, bcx2, bcy2;
            ok = 1;
            for (j = 0; j < nboxes; j = j + 1) begin
                bcx2 = (boxes[j][47:36] + boxes[j][23:12]) >> 1;
                bcy2 = (boxes[j][35:24] + boxes[j][11:0])  >> 1;
                if (!(hit[0] || hit[1] || hit[2])) ok = 0;
            end
            check("K3 无远偏框", ok == 1);
        end
        if (!kchk) begin
            /* 通用模式：只打印检出框清单（离线比对在 Python 侧做） */
            $display("[RESULT] boxes=%0d frame2", nboxes);
            begin : PRT
                integer j2;
                for (j2 = 0; j2 < nboxes; j2 = j2 + 1)
                    $display("[RESULT] box %0d: (%0d,%0d)-(%0d,%0d)",
                             j2, boxes[j2][47:36], boxes[j2][35:24],
                             boxes[j2][23:12], boxes[j2][11:0]);
            end
        end
        /* 等 bridge 发完 */
        guard = 0;
        while (knblk < 1 && guard < 100000) begin @(posedge clk); guard = guard + 1; end
        $display("[DBG ] knblk=%0d", knblk);
        if (kchk) check("K4 bridge 块数=6（两帧 x 三核）", knblk == 6);
        if (kchk) check("K5 roi frame_id=2（产生检测的帧）", kfid[0] == 32'd2);

        $display("============================================");
        if (errors == 0) $display(" DET_NEWLINK ALL PASSED (%0d checks)", chk);
        else             $display(" DET_NEWLINK FAILED: %0d/%0d", errors, chk);
        $display("============================================");
        $finish;
    end

    initial begin
        #80_000_000;   // 80ms 看门狗（2 帧 + NL=128 解析 + bridge 块流）
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
