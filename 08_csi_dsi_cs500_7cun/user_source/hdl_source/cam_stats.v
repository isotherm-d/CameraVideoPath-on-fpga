`timescale 1ns / 1ns
/******************************* CAM CHECK *******************************
* Module Name: cam_stats
* Description: 摄像头链路"体检"统计模块
*   1. 在摄像头像素时钟域(I_clk_pix)统计每秒内的:
*        - 帧数    (I_vsync 每帧 1 个脉冲的次数)
*        - 有效拍数 (I_de 有效且 I_pix 上有数据的拍数)
*        - 非零拍数 (I_pix != 0 的拍数)
*        - 亮度累加和(取 I_pix 中一个字节近似亮度, 由 LUMA_SHIFT 选择位段)
*   2. 在系统时钟域(I_clk_sys)每秒发起一次"快照握手", 把统计结果搬过来。
*   3. 若像素时钟完全没跑(摄像头无输出), 靠 I_clk_sys 侧超时返回全零快照,
*      串口仍每秒打印 f=0 —— 用于区分"链路无数据"和"串口/程序本身坏"。
* 接口约定:
*   I_vsync : 帧起始脉冲, 每帧 1 拍 (对米联客 CSI 例程接 S_raw10_frame_start)
*   I_de    : 数据有效       (对米联客 CSI 例程接 S_raw10_valid)
*   I_pix   : 像素数据       (对米联客 CSI 例程接 S_raw10_data, 40bit=4个RAW10)
* 注意: 像素时钟域的所有寄存器只在下面唯一的 always 块中赋值(多块驱动会报
*       HDL-8007 "constantly driven from multiple places")。
*************************************************************************/

module cam_stats #(
    parameter PIX_W      = 40,             // 像素总线位宽
    parameter LUMA_SHIFT = 2,              // 亮度取样位段: pix[7+LUMA_SHIFT -: 8]
                                           // RAW10(10bit/像素) 建议取 2, 即像素值>>2
    parameter integer CLK_SYS_HZ = 100_000_000  // I_clk_sys 频率, 用于产生1秒节拍
)(
    input  wire             I_clk_pix,      // 摄像头像素时钟 (例程: S_csi_rx_clk)
    input  wire             I_rst_pix,      // 高有效 (例程: ~S_rst_n)
    input  wire             I_vsync,
    input  wire             I_de,
    input  wire [PIX_W-1:0] I_pix,

    input  wire             I_clk_sys,      // 板上稳定时钟, 与摄像头是否出图无关 (例程: S_100m_clk)
    input  wire             I_rst_sys,      // 高有效 (例程: ~S_rst_n)
    output reg              O_snap_valid,   // 每秒 1 拍, 以下结果在本拍有效
    output reg  [31:0]      O_snap_frames,
    output reg  [31:0]      O_snap_pix,
    output reg  [31:0]      O_snap_nonzero,
    output reg  [39:0]      O_snap_sum
);

    // ---------------- 像素时钟域寄存器(全部只在下方一个 always 中赋值) ----------------
    wire [7:0] luma = I_pix[7+LUMA_SHIFT -: 8];

    reg [31:0] r_acc_frames;              // 每秒累加: 帧数
    reg [31:0] r_acc_pix;                 // 每秒累加: 有效拍数
    reg [31:0] r_acc_nz;                  // 每秒累加: 非零拍数
    reg [39:0] r_acc_sum;                 // 每秒累加: 亮度总和
    reg        r_req;                     // (声明在 sys 域使用, 同步读)
    reg        r_ack_t;                   // 像素域 -> sys 域 应答翻转
    reg        r_req_s1, r_req_s2, r_req_d;
    reg [31:0] r_lat_frames, r_lat_pix, r_lat_nz;
    reg [39:0] r_lat_sum;

    // ---------------- 系统时钟域寄存器 ----------------
    reg        r_ack_s1, r_ack_s2, r_ack_d;
    reg [26:0] r_sec_cnt;                 // 1 秒节拍计数 (100MHz 需 27bit)
    reg        r_sec_flag;
    reg [23:0] r_to_cnt;                  // 快照超时 ~168ms@100MHz

    wire w_ack_edge = r_ack_s2 ^ r_ack_d;

    // ---------------- 像素时钟域: 累加 + 快照应答(唯一赋值点) ----------------
    // r_req 经两级同步后检测上升沿: 锁存累加值 -> 清零累加器 -> 翻转应答。
    // 快照那一拍不累加(丢失 1 拍数据, 每秒 1 次, 可忽略)。
    always @(posedge I_clk_pix) begin
        if (I_rst_pix) begin
            r_acc_frames <= 32'd0;
            r_acc_pix    <= 32'd0;
            r_acc_nz     <= 32'd0;
            r_acc_sum    <= 40'd0;
            r_ack_t      <= 1'b0;
            r_req_s1     <= 1'b0;
            r_req_s2     <= 1'b0;
            r_req_d      <= 1'b0;
            r_lat_frames <= 32'd0;
            r_lat_pix    <= 32'd0;
            r_lat_nz     <= 32'd0;
            r_lat_sum    <= 40'd0;
        end else begin
            r_req_s1 <= r_req;
            r_req_s2 <= r_req_s1;
            r_req_d  <= r_req_s2;
            if (r_req_s2 & ~r_req_d) begin    // 快照请求上升沿: 锁存 + 清零
                r_lat_frames <= r_acc_frames;
                r_lat_pix    <= r_acc_pix;
                r_lat_nz     <= r_acc_nz;
                r_lat_sum    <= r_acc_sum;
                r_acc_frames <= 32'd0;
                r_acc_pix    <= 32'd0;
                r_acc_nz     <= 32'd0;
                r_acc_sum    <= 40'd0;
                r_ack_t      <= ~r_ack_t;
            end else begin
                if (I_vsync)
                    r_acc_frames <= r_acc_frames + 1'b1;
                if (I_de) begin
                    r_acc_pix <= r_acc_pix + 1'b1;
                    if (I_pix != {PIX_W{1'b0}})
                        r_acc_nz <= r_acc_nz + 1'b1;
                    r_acc_sum <= r_acc_sum + {32'd0, luma};
                end
            end
        end
    end

    // ---------------- 系统时钟域: 每秒发起一次快照, 带超时兜底 ----------------
    always @(posedge I_clk_sys) begin
        if (I_rst_sys) begin
            r_req     <= 1'b0;
            r_sec_cnt <= 27'd0;
            r_sec_flag<= 1'b0;
            r_to_cnt  <= 24'd0;
            r_ack_s1  <= 1'b0; r_ack_s2 <= 1'b0; r_ack_d <= 1'b0;
            O_snap_valid  <= 1'b0;
            O_snap_frames <= 32'd0;
            O_snap_pix    <= 32'd0;
            O_snap_nonzero<= 32'd0;
            O_snap_sum    <= 40'd0;
        end else begin
            r_ack_s1 <= r_ack_t;
            r_ack_s2 <= r_ack_s1;
            r_ack_d  <= r_ack_s2;
            O_snap_valid <= 1'b0;

            // 1 秒节拍
            if (r_sec_cnt == CLK_SYS_HZ - 1) begin
                r_sec_cnt  <= 27'd0;
                r_sec_flag <= 1'b1;
            end else begin
                r_sec_cnt <= r_sec_cnt + 1'b1;
            end

            if (!r_req) begin
                r_to_cnt <= 24'd0;
                if (r_sec_flag) begin
                    r_sec_flag <= 1'b0;
                    r_req      <= 1'b1;
                    r_to_cnt   <= 24'd1;
                end
            end else begin
                r_to_cnt <= r_to_cnt + 1'b1;
                if (w_ack_edge) begin
                    r_req         <= 1'b0;
                    O_snap_frames <= r_lat_frames;
                    O_snap_pix    <= r_lat_pix;
                    O_snap_nonzero<= r_lat_nz;
                    O_snap_sum    <= r_lat_sum;
                    O_snap_valid  <= 1'b1;
                end else if (&r_to_cnt) begin
                    // 超时: 像素时钟根本没跑 => 摄像头链路无输出, 报全零
                    r_req         <= 1'b0;
                    O_snap_frames <= 32'd0;
                    O_snap_pix    <= 32'd0;
                    O_snap_nonzero<= 32'd0;
                    O_snap_sum    <= 40'd0;
                    O_snap_valid  <= 1'b1;
                end
            end
        end
    end

endmodule
