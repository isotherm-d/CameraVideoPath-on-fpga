/* ============================================================================
 * det_roi_bridge —— detect 检测框 → cvp_patch_bridge roi 接口翻译层（v3 终版）
 * ============================================================================
 * 职责（docs/detect_对接规格书_v1.md + V26队友挂接示例.md）：
 *   把 det_wbc20 的框总线（每帧帧末更新、一整帧保持）转成 cvp_patch_bridge
 *   的逐 ROI 块流：每框一个 1024 字节块（SOP 随第 0 字节、EOP 随第 1023
 *   字节），描述符（frame_id/roi_id/bbox/宽高/格式）随块携带。
 *
 * 【像素分工】本模块**不裁剪像素**：i_pix_en=0 时发全零块（协议合法，
 *   分类侧拿到空图只影响分类结果、不会挂死）。真实像素由 u_roi_pixfill
 *   （后续交付）回读 clean 行缓存填充，就绪后置 i_pix_en=1 并按
 *   o_pix_req 节拍供字节。
 *
 * 【帧号语义】toggle 翻转沿锁存当帧 clean_frame_id——产生检测的那一帧
 *   （det_wbc20 用上一帧像素在帧末算框，输出保持一整帧）。随块透传，
 *   分类/GUI 按 frame_id 对齐，勿用当前帧号。
 *
 * 【快照与丢帧】toggle 翻转整帧快照（s_box/s_fid）。发送中收到新快照：
 *   置 flush，当前块发完（EOP 被接收）后放弃剩余框、回 IDLE 用新快照
 *   重启——队头替换、块不撕裂、不混帧。patch_bridge 的 dropped 端口计
 *   这类放弃。
 *
 * 【时序账】10 框 × 1024 拍 = 10240 拍/帧 << 30fps 帧间 3.33M 拍。
 * ============================================================================
 */
`timescale 1ns/1ps

module det_roi_bridge #(
    parameter integer N_BOX     = 5,    // 与 det_wbc20 N_OUT 一致
    parameter integer BLK_BYTES = 1024,  // patch_bridge 每块字节数（32x32 GRAY8）
    parameter [15:0]  CFG_ID    = 16'd0
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    /* det_wbc20 框总线 */
    input  wire [N_BOX*48-1:0] i_box_xy,
    input  wire        i_box_toggle,     // 每帧框更新翻转一次
    input  wire [31:0] i_frame_id,       // 当帧 clean_frame_id

    /* 像素供给（pixfill：i_pix_en=1 时按 o_pix_req 逐字节供真实灰度） */
    input  wire        i_pix_en,
    input  wire [7:0]  i_pix_data,
    output wire        o_pix_req,

    /* 每框裁剪完成标志（u_roi_pixfill）：S_SOP 按框等待捕获 */
    input  wire [N_BOX-1:0] i_captured,
    output wire        o_blk_start,         // S_SOP 有效块期间高（pixfill 读地址清零）

    /* 结果描述符通道（V26 result_* 接口：GUI 画框用，与像素块独立）。
     * 每有效框一个单拍脉冲；class/score 由 wrapper 侧填充（检测阶段
     * class=0 即"已检出"）。i_desc_ready 拉低时描述符保持等待。 */
    output reg         o_desc_valid,
    input  wire        i_desc_ready,
    output reg  [31:0] o_desc_frame,
    output reg  [15:0] o_desc_roi,
    output reg  [63:0] o_desc_bbox,

    /* cvp_patch_bridge ROI 从机接口（V26 协议） */
    output reg         o_valid,
    input  wire        i_ready,
    output reg  [7:0]  o_data,
    output reg         o_sop,
    output reg         o_eop,
    output reg  [31:0] o_frame_id,
    output reg  [15:0] o_roi_id,
    output reg  [15:0] o_cfg_id,
    output reg  [63:0] o_bbox,          // {x0,y0,x1,y1} 各 16bit（V26 bbox 64bit）
    output reg  [7:0]  o_width,         // 32
    output reg  [7:0]  o_height,        // 32
    output reg  [7:0]  o_channels,      // 1
    output reg  [7:0]  o_format         // 0 = unsigned GRAY8
);

    /* ---------------- 快照：toggle 沿整帧锁存（发送中可覆盖） ----------------
     * s_valid 的读写全部在下方 FSM 块内（单驱动——两个 always 同驱一个
     * reg 在 ModelSim 里碰巧无害，综合 HDL-8007 拒绝，2026-10-10 修正） */
    reg [N_BOX*48-1:0] s_box;
    reg [31:0]         s_fid;
    reg                s_valid;
    reg                r_tog_d;

    wire tog_edge = i_box_toggle ^ r_tog_d;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tog_d <= 1'b0;
        end else begin
            r_tog_d <= i_box_toggle;
        end
    end

    /* ---------------- 发送 FSM ---------------- */
    localparam S_IDLE = 2'd0, S_SOP = 2'd1, S_DATA = 2'd2, S_EOP = 2'd3;

    reg [1:0]  st;
    reg [3:0]  idx;       // 当前框号（描述符用）
    reg [3:0]  left;      // 本快照剩余待发框数
    reg [10:0] bcnt;      // 块内字节计数
    reg        flush;     // 发送中收到新快照：当前块发完即弃剩余
    reg        d_pend;    // 结果描述符待发
    reg [31:0] d_fid;
    reg [15:0] d_roi;
    reg [63:0] d_bbox;

    wire [11:0] cur_x0 = s_box[idx*48 + 36 +: 12];
    wire [11:0] cur_y0 = s_box[idx*48 + 24 +: 12];
    wire [11:0] cur_x1 = s_box[idx*48 + 12 +: 12];
    wire [11:0] cur_y1 = s_box[idx*48       +: 12];
    wire        cur_en = (cur_x0 != 12'hFFF) && (cur_y0 != 12'hFFF) &&
                         (cur_x1 != 12'hFFF) && (cur_y1 != 12'hFFF);

    assign o_pix_req = (st == S_DATA) && o_valid && i_ready;
    assign o_blk_start = (st == S_SOP);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            st <= S_IDLE; idx <= 4'd0; left <= 4'd0; bcnt <= 11'd0;
            flush <= 1'b0; d_pend <= 1'b0;
            o_valid <= 1'b0; o_sop <= 1'b0; o_eop <= 1'b0;
            o_data <= 8'd0; o_frame_id <= 32'd0; o_roi_id <= 16'd0;
            o_cfg_id <= CFG_ID; o_bbox <= 64'd0;
            o_desc_valid <= 1'b0; o_desc_frame <= 32'd0;
            o_desc_roi <= 16'd0; o_desc_bbox <= 64'd0;
            o_width <= 8'd32; o_height <= 8'd32;
            o_channels <= 8'd1; o_format <= 8'd0;
        end else begin
            case (st)
              /* IDLE：有新快照则数有效框（阻塞变量数完再寄存），从 0 号开始 */
              S_IDLE: begin
                  o_valid <= 1'b0;
                  if (s_valid) begin
                      begin : COUNT_BOXES
                          integer i;
                          integer cnt;
                          cnt = 0;
                          for (i = 0; i < N_BOX; i = i + 1)
                              if (s_box[i*48 + 36 +: 12] != 12'hFFF)
                                  cnt = cnt + 1;
                          left <= cnt[3:0];
                      end
                      idx   <= 4'd0;
                      flush <= 1'b0;
                      st    <= S_SOP;
                  end
              end
              /* SOP：跳空框；有效框等裁剪完成（pixfill 逐框标志）后发第 0 字节 */
              S_SOP: begin
                  o_valid <= 1'b0;
                  if (left == 4'd0) begin
                      s_valid <= 1'b0;
                      st      <= S_IDLE;
                  end else if (!cur_en) begin
                      idx <= idx + 1'b1;          // 空框：试下一框
                  end else if (!i_captured[idx]) begin
                      /* 裁剪未完成（行未流过框底）：原地等，帧内必然完成 */
                  end else begin
                      o_frame_id <= s_fid;
                      o_roi_id   <= {12'd0, idx};
                      /* bbox 64bit = {x0,y0,x1,y1} 各 16bit（12bit 坐标零扩展）。
                       * 与 V26 GUI/patch_bridge 的 {x0,y0,x1,y1} 16bit 字段序一致 */
                      o_bbox     <= {4'h0, cur_x0, 4'h0, cur_y0,
                                      4'h0, cur_x1, 4'h0, cur_y1};
                      o_data     <= i_pix_en ? i_pix_data : 8'd0;
                      o_sop      <= 1'b1;
                      o_eop      <= 1'b0;
                      o_valid    <= 1'b1;
                      /* 结果描述符通道：同帧锁存，独立通道待发 */
                      d_pend     <= 1'b1;
                      d_fid      <= s_fid;
                      d_roi      <= {12'd0, idx};
                      d_bbox     <= {4'h0, cur_x0, 4'h0, cur_y0,
                                      4'h0, cur_x1, 4'h0, cur_y1};
                      bcnt       <= 11'd1;
                      st         <= S_DATA;
                  end
              end
              /* DATA：第 1..1023 字节；ready 低原地等（无副作用） */
              S_DATA: begin
                  if (o_valid && i_ready) begin
                      o_sop  <= 1'b0;
                      o_data <= i_pix_en ? i_pix_data : 8'd0;
                      if (bcnt == BLK_BYTES-1) begin
                          o_eop <= 1'b1;
                          st    <= S_EOP;
                      end else begin
                          bcnt <= bcnt + 1'b1;
                      end
                  end
              end
              /* EOP：块收尾。flush=1 弃剩余回 IDLE（保留 s_valid，新快照
               * 由 IDLE 重新数框启动）；否则推进下一框 */
              S_EOP: begin
                  o_valid <= 1'b0;
                  o_eop   <= 1'b0;
                  if (flush) begin
                      flush <= 1'b0;   /* s_valid 保持：新快照待发 */
                      st    <= S_IDLE;
                  end else begin
                      left <= left - 1'b1;
                      if (left == 4'd1) begin
                          s_valid <= 1'b0;
                          st      <= S_IDLE;
                      end else begin
                          idx <= idx + 1'b1;
                          st  <= S_SOP;
                      end
                  end
              end
              default: st <= S_IDLE;
            endcase

            /* 新快照到达（任意状态）：锁存坐标+置 s_valid（放 case 之后 =
             * 最高优先级，覆盖同拍 case 内的 s_valid<=0）；发送中标记 flush。
             * S_IDLE/S_SOP 阶段剩余未发，直接作废当前遍历回 IDLE 重数。
             * 待发描述符作废（换新框坐标，结果通道天然容忍丢帧）。 */
            if (tog_edge) begin
                s_box   <= i_box_xy;
                s_fid   <= i_frame_id;
                s_valid <= 1'b1;
                d_pend  <= 1'b0;
                if (st == S_IDLE || st == S_SOP) begin
                    st    <= (st == S_SOP) ? S_IDLE : st;
                    flush <= 1'b0;
                end else begin
                    flush <= 1'b1;   // S_DATA/S_EOP：当前块发完再弃剩余
                end
            end

            /* 结果描述符发送（单驱动：本块管理 d_pend；ready 握手独立于
             * 像素块，不阻塞 1024 字节流） */
            o_desc_valid <= 1'b0;
            if (d_pend && i_desc_ready) begin
                o_desc_valid <= 1'b1;
                o_desc_frame <= d_fid;
                o_desc_roi   <= d_roi;
                o_desc_bbox  <= d_bbox;
                d_pend       <= 1'b0;
            end
        end
    end

endmodule
