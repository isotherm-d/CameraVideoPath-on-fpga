// ============================================================================
// cellnet_top.v — 五类白细胞分类 CNN 推理核（int8 权重 / uint8 激活, 整数定点）
//
// 拓扑: 3x(conv3x3 pad1 + round-shift-requant + relu) + maxpool2x2 x2 + GAP + FC
// 数据流: img_mem(32x32x3) -> p1_mem(16x16xC1) -> p2_mem(8x8xC2) -> gap_sum -> logits
//
// 资源策略: 单 MAC 串行复用, LUT 占用与通道数无关; 权重/图像/特征图全部
//           映射同步读 RAM, 由综合器推断 ERAM/dram。
// 精度约定: 与 py/fixed32.py 的整数 golden 模型严格位对齐
//   out_q = clamp(((acc + (1<<(S-1))) >>> S), 0, 255)
// ============================================================================
`timescale 1ns/1ps

module cellnet32_core #(
    parameter WROM_FILE = "../../../user_source/hdl_source/classify/model/wrom.hex"
) (
    input  wire         clk,
    input  wire         rst_n,
    // ---- 图像加载口: 32x32x3 = 3072B, 布局 ch*1024 + y*32 + x ----
    input  wire [11:0]  img_waddr,
    input  wire [7:0]   img_wdata,
    input  wire         img_we,
    // ---- 控制 ----
    input  wire         start,
    output reg          busy,
    output reg          done,
    output reg  [2:0]   pred,          // argmax 类别 0..4
    output wire [159:0] logits_flat    // 5 x int32 (2 的补码)
);

// 32x32 export: requires the 32x32 RTL; not compatible with old 28x28 top.
localparam IMG_DIM = 32, P1_DIM = 16, P2_DIM = 8, GAP_COUNT = 64;
localparam C1 = 6, C2 = 12, C3 = 24, IN_CH = 3;
localparam S1 = 6, S2 = 6, S3 = 8;
localparam PW1 = 4, PW2 = 6, PW3 = 6, PWF = 6;
localparam BASE_W1 = 0;
localparam BASE_B1 = 41;
localparam BASE_W2 = 47;
localparam BASE_B2 = 209;
localparam BASE_W3 = 221;
localparam BASE_B3 = 869;
localparam BASE_FCW = 893;
localparam BASE_FCB = 923;
localparam WROM_WORDS = 928;


    // ---- 存储体 ----
    reg  [7:0]  img_mem [0:IMG_DIM*IMG_DIM*IN_CH-1];
    reg  [7:0]  p1_mem  [0:C1*P1_DIM*P1_DIM-1];
    reg  [7:0]  p2_mem  [0:C2*P2_DIM*P2_DIM-1];
    reg  [31:0] wrom    [0:WROM_WORDS-1];
    initial $readmemh(WROM_FILE, wrom);

    // 同步读端口
    reg  [11:0] img_raddr;  reg [7:0] img_rd;
    reg  [10:0] p1_raddr;   reg [7:0] p1_rd;
    reg  [9:0]  p2_raddr;   reg [7:0] p2_rd;
    reg  [15:0] wr_addr;    reg [31:0] wr_rd;
    always @(posedge clk) begin
        img_rd <= img_mem[img_raddr];
        p1_rd  <= p1_mem[p1_raddr];
        p2_rd  <= p2_mem[p2_raddr];
        wr_rd  <= wrom[wr_addr];
    end

    // 行缓冲 (conv 输出行对, 索引 col*16+ch)
    reg  [7:0] rbuf0 [0:IMG_DIM*16-1];
    reg  [7:0] rbuf1 [0:IMG_DIM*16-1];
    reg  [8:0] rb_addr;   reg [7:0] rb_rd0, rb_rd1;
    always @(posedge clk) begin
        rb_rd0 <= rbuf0[rb_addr];
        rb_rd1 <= rbuf1[rb_addr];
    end

    // GAP: 8x8 项, 最大 64*255=16320, 14 bit 足够
    reg [13:0] gap_sum [0:C3-1];

    // ---- FSM ----
    localparam ST_IDLE  = 6'd0,  ST_SET  = 6'd1,  ST_ADDR = 6'd2,
               ST_RD    = 6'd3,  ST_MAC  = 6'd4,  ST_BRD  = 6'd5,
               ST_BADD  = 6'd6,  ST_OUT  = 6'd7,
               ST_PRA   = 6'd8,  ST_PRB  = 6'd9,  ST_PRC  = 6'd10,
               ST_PRD   = 6'd11, ST_FADD = 6'd12,
               ST_FSET  = 6'd13, ST_FBRD = 6'd14, ST_FADDR= 6'd15,
               ST_FRD   = 6'd16, ST_FMAC = 6'd17, ST_FST  = 6'd18,
               ST_ARG   = 6'd19, ST_FNEXT= 6'd20, ST_PRE  = 6'd21;

    reg [5:0]  state;
    reg [1:0]  layer;        // 0/1/2
    reg [4:0]  orow, ocol;   // 输出特征图坐标
    reg [5:0]  och;          // 输出通道
    reg [1:0]  ky, kx;
    reg [5:0]  ic;
    reg [15:0] baddr;        // 层内权重字节偏移
    reg [15:0] wb_base;      // 层权重起始字节地址
    reg  signed [31:0] acc;
    reg  [15:0] bsel;        // 当前权重字节地址
    reg  [4:0]  prow, pcol;
    reg  [5:0]  pch;
    reg  [7:0]  m0, m2;
    reg  [4:0]  f_oc;
    reg  [5:0]  f_j;
    reg  [13:0] gsum_cap;
    reg  signed [31:0] lg [0:4];

    assign logits_flat = {lg[0], lg[1], lg[2], lg[3], lg[4]};

    // ---- 当前层配置 ----
    wire [5:0]  IDIM  = (layer == 2'd0) ? IMG_DIM[5:0] :
                        (layer == 2'd1) ? P1_DIM[5:0] : P2_DIM[5:0];
    wire [5:0]  ICH   = (layer == 2'd0) ? IN_CH[5:0] :
                        (layer == 2'd1) ? C1[5:0]    : C2[5:0];
    wire [5:0]  OCH_N = (layer == 2'd0) ? C1[5:0] :
                        (layer == 2'd1) ? C2[5:0]    : C3[5:0];
    wire [3:0]  S_CUR = (layer == 2'd0) ? S1[3:0] :
                        (layer == 2'd1) ? S2[3:0]    : S3[3:0];
    wire [15:0] B_BASE= (layer == 2'd0) ? BASE_B1[15:0] :
                        (layer == 2'd1) ? BASE_B2[15:0] : BASE_B3[15:0];

    // 窗口坐标 (补边 → 越界读 0)
    reg signed [6:0] wr_c, wc_c;
    always @* begin
        wr_c = $signed({2'b0, orow}) + $signed({1'b0, ky}) - 7'sd1;
        wc_c = $signed({2'b0, ocol}) + $signed({1'b0, kx}) - 7'sd1;
    end
    wire oob = (wr_c < 0) || (wr_c >= $signed({2'b0, IDIM})) ||
               (wc_c < 0) || (wc_c >= $signed({2'b0, IDIM}));
    // 32/16/8 都是 2 的幂: 用移位生成平面地址, 避免地址乘法占用 DSP。
    wire [11:0] ch_addr  = {6'b0, ic};
    wire [11:0] row_addr = {6'b0, wr_c[5:0]};
    wire [11:0] col_addr = {6'b0, wc_c[5:0]};
    wire [11:0] pixaddr_raw = (layer == 2'd0) ?
                                  ((ch_addr << 10) + (row_addr << 5) + col_addr) :
                              (layer == 2'd1) ?
                                  ((ch_addr << 8) + (row_addr << 4) + col_addr) :
                                  ((ch_addr << 6) + (row_addr << 3) + col_addr);
    wire [11:0] pixaddr = oob ? 12'd0 : pixaddr_raw;
    wire [7:0] pix = oob ? 8'd0 :
                     (layer == 2'd0) ? img_rd :
                     (layer == 2'd1) ? p1_rd  : p2_rd;
    always @* begin
        // 非活动层也必须赋值, 避免旧版地址端口推断 latch。
        img_raddr = 12'd0;
        p1_raddr  = 11'd0;
        p2_raddr  = 10'd0;
        case (layer)
            2'd0:    img_raddr = pixaddr;
            2'd1:    p1_raddr  = pixaddr[10:0];
            default: p2_raddr  = pixaddr[9:0];
        endcase
    end

    // 权重字节选择 (小端: byte0 = [7:0])
    wire [7:0] wbyte = (bsel[1:0] == 2'd0) ? wr_rd[7:0]  :
                       (bsel[1:0] == 2'd1) ? wr_rd[15:8] :
                       (bsel[1:0] == 2'd2) ? wr_rd[23:16]: wr_rd[31:24];

    // requant: round-half-up 右移 + relu + clamp255
    wire signed [39:0] acc40 = acc;              // 符号扩展
    wire signed [39:0] rnd   = acc40 + (40'sd1 << (S_CUR - 4'd1));
    wire signed [39:0] shft  = rnd >>> S_CUR;
    wire [7:0] obyte_w = (acc40[39] || shft[39]) ? 8'd0 :
                         (shft > 40'sd255) ? 8'd255 : shft[7:0];

    // FC: 权重保持完整 int8 精度, /64 折入最终公共小数位及 bias 定标。
    // RTL 只需对 64 项 GAP 和做乘加, argmax 无需执行除法。
    wire [15:0] fcw_base_b = BASE_FCW[15:0] * 16'd4;
    wire [13:0] gsum_r     = gap_sum[f_j];

    wire last_tap = (ic == ICH - 6'd1) && (kx == 2'd2) && (ky == 2'd2);

    // 池化: 行对缓冲地址 = (col*16 + ch), 行对完成于 orow 为奇数时
    wire [8:0] pa0 = {pcol, 1'b0, 4'b0} + {3'b0, pch[3:0]};   // (2*pcol)*16+ch
    wire [8:0] pa1 = pa0 + 9'd16;
    wire [7:0] pm_a   = (m0 > m2) ? m0 : m2;                  // 左列(第2R行对)
    wire [7:0] pm_b   = (rb_rd0 > rb_rd1) ? rb_rd0 : rb_rd1;  // 右列(当拍有效)
    wire [7:0] pmax   = (pm_a > pm_b) ? pm_a : pm_b;
    wire [11:0] pool_ch  = {6'b0, pch};
    wire [11:0] pool_row = {7'b0, prow};
    wire [11:0] pool_col = {7'b0, pcol};
    wire [11:0] pm_addr = (layer == 2'd0) ?
                              ((pool_ch << 8) + (pool_row << 4) + pool_col) :
                              ((pool_ch << 6) + (pool_row << 3) + pool_col);

    // rbuf 写索引 = ocol*16 + och
    wire [8:0] rb_widx = {ocol, 4'b0} + {3'b0, och[3:0]};

    // argmax (平局取小标号, 与 np.argmax 一致)
    reg [2:0] pred_w;
    always @* begin
        if (lg[0] >= lg[1] && lg[0] >= lg[2] && lg[0] >= lg[3] && lg[0] >= lg[4])
            pred_w = 3'd0;
        else if (lg[1] >= lg[2] && lg[1] >= lg[3] && lg[1] >= lg[4])
            pred_w = 3'd1;
        else if (lg[2] >= lg[3] && lg[2] >= lg[4])
            pred_w = 3'd2;
        else if (lg[3] >= lg[4])
            pred_w = 3'd3;
        else
            pred_w = 3'd4;
    end

    integer k;
    initial begin
        for (k = 0; k < IMG_DIM*16; k = k + 1) begin
            rbuf0[k] = 8'd0; rbuf1[k] = 8'd0;
        end
        for (k = 0; k < C3; k = k + 1) gap_sum[k] = 14'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; busy <= 1'b0; done <= 1'b0; pred <= 3'd0;
            layer <= 2'd0; orow <= 5'd0; ocol <= 5'd0; och <= 6'd0;
            ky <= 2'd0; kx <= 2'd0; ic <= 6'd0; baddr <= 16'd0;
            acc <= 32'sd0; bsel <= 16'd0; f_oc <= 5'd0; f_j <= 6'd0;
        end else begin
            done <= 1'b0;
            if (img_we) img_mem[img_waddr] <= img_wdata;
            case (state)
            // ---------- 空闲 ----------
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy  <= 1'b1;
                    layer <= 2'd0; orow <= 5'd0; ocol <= 5'd0; och <= 6'd0;
                    wb_base <= BASE_W1 * 16'd4;
                    for (k = 0; k < C3; k = k + 1) gap_sum[k] <= 14'd0;
                    state <= ST_SET;
                end
            end
            // ---------- conv: 每输出像素 ----------
            ST_SET: begin
                ky <= 2'd0; kx <= 2'd0; ic <= 6'd0;
                baddr <= och * (6'd9 * ICH);        // 本通道权重块起始
                acc <= 32'sd0;
                state <= ST_ADDR;
            end
            ST_ADDR: begin
                bsel    <= wb_base + baddr;
                wr_addr <= (wb_base + baddr) >> 2;
                state   <= ST_RD;
            end
            ST_RD: state <= ST_MAC;
            ST_MAC: begin
`ifdef CELLNET_DEBUG
                if (orow < 2 && ocol < 2 && och < 2 && layer == 2'd1)
                    $display("DBG M L1 (%0d,%0d,ch%0d) ky%0d kx%0d ic%0d pix=%0d w=%0d oob=%b paddr=%0d bsel=%0d",
                             orow, ocol, och, ky, kx, ic, pix, $signed(wbyte),
                             oob, pixaddr, bsel);
`endif
                acc   <= acc + $signed(wbyte) * $signed({1'b0, pix});
                baddr <= baddr + 16'd1;
                if (last_tap) begin
                    wr_addr <= B_BASE + {10'b0, och[5:0]};
                    state   <= ST_BRD;
                end else begin
                    if (ic == ICH - 6'd1) begin
                        ic <= 6'd0;
                        if (kx == 2'd2) begin
                            kx <= 2'd0;
                            ky <= ky + 2'd1;
                        end else kx <= kx + 2'd1;
                    end else ic <= ic + 6'd1;
                    state <= ST_ADDR;
                end
            end
            ST_BRD: state <= ST_BADD;                       // 等 bias 字读出
            ST_BADD: begin
                acc   <= acc + $signed(wr_rd);
                state <= ST_OUT;
            end
            ST_OUT: begin
                // 写结果: conv1/2 -> 行缓冲, conv3 -> GAP 累加
`ifdef CELLNET_DEBUG
                if (ocol < 2 && och < 2)
                    $display("DBG L%0d (%0d,%0d,ch%0d) acc=%0d obyte=%0d",
                             layer, orow, ocol, och, acc, obyte_w);
`endif
                if (layer == 2'd2)
                    gap_sum[och] <= gap_sum[och] + {6'b0, obyte_w};
                else if (orow[0])
                    rbuf1[rb_widx] <= obyte_w;
                else
                    rbuf0[rb_widx] <= obyte_w;
                // 推进坐标
                if (och != OCH_N - 6'd1) begin
                    och   <= och + 6'd1;
                    state <= ST_SET;
                end else if (ocol != IDIM - 5'd1) begin
                    och   <= 6'd0;
                    ocol  <= ocol + 5'd1;
                    state <= ST_SET;
                end else begin
                    och <= 6'd0;
                    if (layer == 2'd2) begin            // conv3: 最后一行完 -> FC
                        if (orow == P2_DIM - 1) begin
                            f_oc  <= 5'd0;
                            state <= ST_FSET;
                        end else begin
                            orow  <= orow + 5'd1;
                            ocol  <= 5'd0;
                            state <= ST_SET;
                        end
                    end else if (orow[0]) begin         // 偶数对完成 -> 池化
                        prow  <= orow[4:1];
                        pcol  <= 5'd0;
                        pch   <= 6'd0;
                        state <= ST_PRA;
                    end else begin
                        orow  <= orow + 5'd1;
                        ocol  <= 5'd0;
                        state <= ST_SET;
                    end
                end
            end
            // ---------- 池化行扫描 (读 4 个行缓冲字节求 max) ----------
            // 同步读 1 拍延迟: 发地址 -> 等待 -> 采样
            ST_PRA: begin
                rb_addr <= pa0;                         // 发 (2c)*16+ch
                state   <= ST_PRB;
            end
            ST_PRB: state <= ST_PRC;                    // 等 rbuf 读出
            ST_PRC: begin
                m0      <= rb_rd0;                      // buf0[(2c)*16+ch]
                m2      <= rb_rd1;                      // buf1[(2c)*16+ch]
                rb_addr <= pa1;                         // 发 (2c+1)*16+ch
                state   <= ST_PRD;
            end
            ST_PRD: state <= ST_PRE;                    // 等 pa1 读出 (PRE 拍有效)
            ST_PRE: begin
`ifdef CELLNET_DEBUG
                if (prow == 5'd0 && pcol == 5'd0 && pch < 6'd3)
                    $display("DBG POOL ch%0d L=[%0d,%0d] R=[%0d,%0d] max=%0d addr=%0d",
                             pch, m0, m2, rb_rd0, rb_rd1, pmax, pm_addr);
`endif
                if (layer == 2'd0) p1_mem[pm_addr] <= pmax;
                else               p2_mem[pm_addr] <= pmax;
                if (pch != OCH_N - 6'd1) begin
                    pch   <= pch + 6'd1;
                    state <= ST_PRA;
                end else if (pcol != (IDIM >> 1) - 5'd1) begin
                    pch   <= 6'd0;
                    pcol  <= pcol + 5'd1;
                    state <= ST_PRA;
                end else if (prow == (IDIM >> 1) - 5'd1) begin
                    // 本层全部完成 -> 下一层
`ifdef CELLNET_DEBUG
                    $display("DBG LAYER %0d DONE at %0t", layer, $time);
`endif
                    layer   <= layer + 2'd1;
                    orow    <= 5'd0; ocol <= 5'd0; och <= 6'd0;
                    wb_base <= (layer == 2'd0) ? BASE_W2 * 16'd4
                                               : BASE_W3 * 16'd4;
                    state   <= ST_SET;
                end else begin
                    pch   <= 6'd0;
                    orow  <= orow + 5'd1;               // 下一对行
                    ocol  <= 5'd0;
                    state <= ST_SET;
                end
            end
            // ---------- FC: 5 类 x C3 ----------
            ST_FSET: begin
                wr_addr <= BASE_FCB + {11'b0, f_oc};
                state   <= ST_FBRD;
            end
            ST_FBRD: begin                                // 等 bias 字读出
                f_j   <= 6'd0;
                state <= ST_FADD;
            end
            ST_FADD: begin                                // acc 载入 bias, 发第 0 个权重读
                acc      <= $signed(wr_rd);
                bsel     <= fcw_base_b + f_oc * C3[5:0];
                wr_addr  <= (fcw_base_b + f_oc * C3[5:0]) >> 2;
                gsum_cap <= gsum_r;
                state    <= ST_FRD;
            end
            ST_FRD: state <= ST_FMAC;
            ST_FMAC: begin
                acc <= acc + $signed(wbyte) * $signed({2'b0, gsum_cap});
                if (f_j == C3 - 6'd1) state <= ST_FST;
                else begin
                    f_j   <= f_j + 6'd1;
                    state <= ST_FNEXT;
                end
            end
            ST_FNEXT: begin                               // 发下一个权重读
                bsel     <= fcw_base_b + f_oc * C3[5:0] + f_j;
                wr_addr  <= (fcw_base_b + f_oc * C3[5:0] + f_j) >> 2;
                gsum_cap <= gsum_r;
                state    <= ST_FRD;
            end
            ST_FST: begin
                lg[f_oc] <= acc;
                if (f_oc == 5'd4) state <= ST_ARG;
                else begin
                    f_oc  <= f_oc + 5'd1;
                    state <= ST_FSET;
                end
            end
            ST_ARG: begin
                pred  <= pred_w;
                done  <= 1'b1;
                busy  <= 1'b0;
                state <= ST_IDLE;
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
