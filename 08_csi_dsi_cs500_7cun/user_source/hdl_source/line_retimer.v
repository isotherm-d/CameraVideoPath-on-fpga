`timescale 1ns / 1ps
/*****************************************************************
 @Description : 帧内按 valid 序号重新切行(v11f):
                上游(image_correction/raw10 层)的行切分实测不稳定
                (行长 255~256 拍抖动, 心跳监视器读数), 导致 uial2axis
                按 256 拍切的行与真实图像行错位 -> 每行滑 ~1 拍的斜条纹。
                本模块不看上游 tlast/间隙, 只按帧内 valid 序号切行:
                tuser 拍为 (行0,列0), 之后每个有效拍坐标+1,
                每行第 BEATS_PER_LINE 拍为行尾, 共 LINES 行截断
                (帧内多余拍丢弃, 防上游行间杂散挤入)。
                坐标寄存器语义 = "下一个有效拍的坐标"(tuser 拍直接视为 0,0,
                不读寄存器, 规避非阻塞旧值问题)。
*****************************************************************/
module line_retimer #(
    parameter BEATS_PER_LINE = 256,    // 每行拍数(IMG_WIDTH/4)
    parameter LINES          = 600     // 每帧行数
)(
    input           I_clk,
    input           I_rst_n,

    input           I_tuser,     // 上游帧首(与 valid 同拍)
    input           I_tvalid,
    input  [39:0]   I_tdata,

    output reg      O_tuser,     // 重切后的帧首(帧内第 1 个有效拍)
    output reg      O_tvalid,
    output reg      O_tlast,     // 重切后的行尾
    output reg [39:0] O_tdata,
    output reg      O_ovf        // v21c DIAG: 上帧未结束就来新帧首(行数超窗)
);

    reg [10:0] r_col;       // 下一有效拍的列坐标
    reg [10:0] r_row;       // 下一有效拍的行坐标
    reg        r_in_frame;  // 帧窗口内(tuser 已见, 未满)

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_col      <= 11'd0;
            r_row      <= 11'd0;
            r_in_frame <= 1'b0;
        end else if (I_tvalid) begin
            if (I_tuser && r_in_frame && (r_row != 11'd0 || r_col != 11'd1))
                O_ovf <= 1'b1;                    // v21c DIAG: 帧未结束收到新帧首
            if (I_tuser) begin
                // 帧首拍本身 = (0,0); 拍末设置下一拍坐标 (0,1)
                r_in_frame <= 1'b1;
                r_col      <= 11'd1;
                r_row      <= 11'd0;
            end else if (r_in_frame) begin
                // 本拍坐标 = (r_row, r_col); 推进
                if (r_col == BEATS_PER_LINE - 1) begin
                    r_col <= 11'd0;
                    if (r_row == LINES - 1)
                        r_in_frame <= 1'b0;      // 帧满, 后续丢弃到下个 tuser
                    else
                        r_row <= r_row + 11'd1;
                end else begin
                    r_col <= r_col + 11'd1;
                end
            end
            // !r_in_frame && !I_tuser: 帧外杂散拍, 直接丢弃
        end
    end

    // 输出延迟链(3 拍, 坐标流水跟随)
    reg        v_d1, v_d2, u_d1, u_d2, l_d1, l_d2;
    reg [39:0] d_d1, d_d2;

    wire w_pass = I_tvalid && (I_tuser || r_in_frame);
    wire w_last = w_pass && !I_tuser && (r_col == BEATS_PER_LINE - 1);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            v_d1 <= 0; v_d2 <= 0;
            u_d1 <= 0; u_d2 <= 0;
            l_d1 <= 0; l_d2 <= 0;
            d_d1 <= 0; d_d2 <= 0;
            O_tvalid <= 0; O_tuser <= 0; O_tlast <= 0; O_tdata <= 0;
            O_ovf <= 0;
        end else begin
            v_d1 <= w_pass;      v_d2 <= v_d1;
            u_d1 <= w_pass && I_tuser;  u_d2 <= u_d1;
            l_d1 <= w_last;      l_d2 <= l_d1;
            d_d1 <= I_tdata;     d_d2 <= d_d1;

            O_tvalid <= v_d2;
            O_tuser  <= u_d2;
            O_tlast  <= l_d2;
            O_tdata  <= d_d2;
        end
    end

endmodule
