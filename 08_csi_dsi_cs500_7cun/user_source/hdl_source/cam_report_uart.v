`timescale 1ns / 1ns
/******************************* CAM CHECK *******************************
* Module Name: cam_report_uart
* Description: 每秒把 cam_stats 的快照打印成一行 ASCII (115200-8-N-1):
*   CAM t=1234567890 f=<帧数> p=<有效拍数> nz=<非零拍数> sum=<亮度总和>\r\n
*   其中 t= 是固定自检值(1234567890): t 打对了说明打印路径正常,其余数字才可信。
*   数字转换用 double-dabble(移位+加3), 只用移位/比较/case, 不用除法器、
*   不用数组、不用变量下标 —— 规避综合器对这类结构的兼容性问题。
*   发送驱动复用米联客 uiuart_tx (wreq 上升沿启动一次发送)。
*************************************************************************/

module cam_report_uart #(
    parameter integer CLK_HZ = 100_000_000,   // I_clk 频率 (例程: S_100m_clk)
    parameter integer BAUD   = 115200
)(
    input  wire        I_clk,
    input  wire        I_rst_n,               // 低有效, 直接接例程的 S_rst_n
    input  wire        I_snap_valid,
    input  wire [31:0] I_snap_frames,
    input  wire [31:0] I_snap_pix,
    input  wire [31:0] I_snap_nonzero,
    input  wire [39:0] I_snap_sum,

    // 第二统计通道(ISP 观测口), 与第一通道同拍快照, 打印为第二行 "ISP ..."
    input  wire        I_isp_valid,
    input  wire [31:0] I_isp_frames,
    input  wire [31:0] I_isp_pix,
    input  wire [31:0] I_isp_nonzero,
    input  wire [39:0] I_isp_sum,
    output wire        O_uart_tx
);

    // 状态
    localparam S_IDLE = 4'd0;   // 等快照
    localparam S_SEG  = 4'd1;   // 分发下一段
    localparam S_CONV = 4'd2;   // double-dabble 转换, 40 拍
    localparam S_CNT  = 4'd3;   // 计算有效位数(去前导零)
    localparam S_STR  = 4'd4;   // 发送固定字符串
    localparam S_SEND = 4'd5;   // 发送数字

    reg [3:0]  r_state;
    reg [31:0] r_frames, r_pix, r_nz;
    reg [39:0] r_sum;
    reg [31:0] r_isp_frames, r_isp_pix, r_isp_nz;   // 第二通道(ISP)快照
    reg [39:0] r_isp_sum;
    reg        r_chn;                               // 当前打印行: 0=CAM 1=ISP

    // 按打印行选择字段值
    wire [31:0] w_frames = r_chn ? r_isp_frames : r_frames;
    wire [31:0] w_pix    = r_chn ? r_isp_pix    : r_pix;
    wire [31:0] w_nz     = r_chn ? r_isp_nz     : r_nz;
    wire [39:0] w_sum    = r_chn ? r_isp_sum    : r_sum;

    // ---- double-dabble: 待转值(40bit) + 12 个 BCD 位(独立寄存器) ----
    reg [39:0] r_val;
    reg [5:0]  r_ddi;
    reg [3:0]  r_b0,  r_b1,  r_b2,  r_b3,  r_b4,  r_b5;
    reg [3:0]  r_b6,  r_b7,  r_b8,  r_b9,  r_b10, r_b11;
    reg [3:0]  r_dcnt;          // 有效十进制位数 1..12
    reg [3:0]  r_send_i;

    // ---- 分段打印 ----
    // 段号: 0"CAM t=" 1<t自检值> 2" f=" 3<帧> 4" p=" 5<拍数> 6" nz=" 7<非零>
    //       8" sum=" 9<亮度总和> 10"\r\n" 11->结束
    reg [3:0]  r_seg;
    reg [3:0]  r_str_i;
    reg [3:0]  r_str_len;
    reg        r_st_go;         // 给 uiuart_tx 的单拍发送请求(上升沿触发)
    reg [7:0]  r_tx_data;

    // ---- double-dabble 每拍组合逻辑: BCD>=5 则 +3 ----
    wire [3:0] w_a0  = (r_b0  >= 4'd5) ? r_b0  + 4'd3 : r_b0;
    wire [3:0] w_a1  = (r_b1  >= 4'd5) ? r_b1  + 4'd3 : r_b1;
    wire [3:0] w_a2  = (r_b2  >= 4'd5) ? r_b2  + 4'd3 : r_b2;
    wire [3:0] w_a3  = (r_b3  >= 4'd5) ? r_b3  + 4'd3 : r_b3;
    wire [3:0] w_a4  = (r_b4  >= 4'd5) ? r_b4  + 4'd3 : r_b4;
    wire [3:0] w_a5  = (r_b5  >= 4'd5) ? r_b5  + 4'd3 : r_b5;
    wire [3:0] w_a6  = (r_b6  >= 4'd5) ? r_b6  + 4'd3 : r_b6;
    wire [3:0] w_a7  = (r_b7  >= 4'd5) ? r_b7  + 4'd3 : r_b7;
    wire [3:0] w_a8  = (r_b8  >= 4'd5) ? r_b8  + 4'd3 : r_b8;
    wire [3:0] w_a9  = (r_b9  >= 4'd5) ? r_b9  + 4'd3 : r_b9;
    wire [3:0] w_a10 = (r_b10 >= 4'd5) ? r_b10 + 4'd3 : r_b10;
    wire [3:0] w_a11 = (r_b11 >= 4'd5) ? r_b11 + 4'd3 : r_b11;

    function [7:0] str_rom(input [3:0] s, input [3:0] i);
        case (s)
            4'd0:  str_rom = (i == 0) ? (r_chn ? "I" : "C") :
                             (i == 1) ? (r_chn ? "S" : "A") :
                             (i == 2) ? (r_chn ? "P" : "M") :
                             (i == 3) ? " " : (i == 4) ? "t" : "=" ;
            4'd2:  str_rom = (i == 0) ? " " : (i == 1) ? "f" : "=" ;
            4'd4:  str_rom = (i == 0) ? " " : (i == 1) ? "p" : "=" ;
            4'd6:  str_rom = (i == 0) ? " " : (i == 1) ? "n" : (i == 2) ? "z" : "=" ;
            4'd8:  str_rom = (i == 0) ? " " : (i == 1) ? "s" : (i == 2) ? "u" :
                             (i == 3) ? "m" : "=" ;
            4'd10: str_rom = (i == 0) ? "\r" : "\n" ;
            default: str_rom = " ";
        endcase
    endfunction

    function [3:0] str_len(input [3:0] s);
        case (s)
            4'd0:  str_len = 4'd6;    // "CAM t="
            4'd2:  str_len = 4'd3;    // " f="
            4'd4:  str_len = 4'd3;    // " p="
            4'd6:  str_len = 4'd4;    // " nz="
            4'd8:  str_len = 4'd5;    // " sum="
            4'd10: str_len = 4'd2;    // CRLF
            default: str_len = 4'd0;
        endcase
    endfunction

    // ---------- 米联客 uiuart_tx 发送驱动 ----------
    wire       w_tx_busy;
    uiuart_tx #(
        .BAUD_DIV(CLK_HZ / BAUD - 1)
    ) u_uart_tx (
        .I_clk        (I_clk),
        .I_uart_rstn  (I_rst_n),
        .I_uart_wreq  (r_st_go),
        .I_uart_wdata (r_tx_data),
        .O_uart_wbusy (w_tx_busy),
        .O_uart_tx    (O_uart_tx)
    );

    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            r_state   <= S_IDLE;
            r_frames  <= 32'd0;
            r_pix     <= 32'd0;
            r_nz      <= 32'd0;
            r_sum     <= 40'd0;
            r_isp_frames <= 32'd0;
            r_isp_pix    <= 32'd0;
            r_isp_nz     <= 32'd0;
            r_isp_sum    <= 40'd0;
            r_chn     <= 1'b0;
            r_val     <= 40'd0;
            r_ddi     <= 6'd0;
            r_b0 <= 4'd0;  r_b1 <= 4'd0;  r_b2 <= 4'd0;  r_b3 <= 4'd0;
            r_b4 <= 4'd0;  r_b5 <= 4'd0;  r_b6 <= 4'd0;  r_b7 <= 4'd0;
            r_b8 <= 4'd0;  r_b9 <= 4'd0;  r_b10 <= 4'd0; r_b11 <= 4'd0;
            r_dcnt    <= 4'd1;
            r_send_i  <= 4'd0;
            r_seg     <= 4'd0;
            r_str_i   <= 4'd0;
            r_str_len <= 4'd0;
            r_st_go   <= 1'b0;
            r_tx_data <= 8'd0;
        end else begin
            r_st_go <= 1'b0;              // 默认单拍脉冲
            case (r_state)
                // 等待每秒一次的快照
                S_IDLE: begin
                    if (I_snap_valid) begin
                        r_frames <= I_snap_frames;
                        r_pix    <= I_snap_pix;
                        r_nz     <= I_snap_nonzero;
                        r_sum    <= I_snap_sum;
                        r_isp_frames <= I_isp_frames;
                        r_isp_pix    <= I_isp_pix;
                        r_isp_nz     <= I_isp_nonzero;
                        r_isp_sum    <= I_isp_sum;
                        r_chn    <= 1'b0;
                        r_seg    <= 4'd0;
                        r_state  <= S_SEG;
                    end
                end
                // 段分发: 奇数段是数字, 其余是固定字符串
                S_SEG: begin
                    case (r_seg)
                        4'd1, 4'd3, 4'd5, 4'd7, 4'd9: begin
                            case (r_seg)          // 装载待转换的值(按打印行选字段)
                                4'd1:    r_val <= 40'd2026100340;           // 构建指纹: 串口 t= 可辨认板上固件版本
                                4'd3:    r_val <= {8'd0, w_frames};
                                4'd5:    r_val <= {8'd0, w_pix};
                                4'd7:    r_val <= {8'd0, w_nz};
                                default: r_val <= w_sum;
                            endcase
                            r_ddi <= 6'd0;
                            r_b0 <= 4'd0;  r_b1 <= 4'd0;  r_b2 <= 4'd0;  r_b3 <= 4'd0;
                            r_b4 <= 4'd0;  r_b5 <= 4'd0;  r_b6 <= 4'd0;  r_b7 <= 4'd0;
                            r_b8 <= 4'd0;  r_b9 <= 4'd0;  r_b10 <= 4'd0; r_b11 <= 4'd0;
                            r_state <= S_CONV;
                            r_seg   <= r_seg + 1'b1;
                        end
                        4'd11: begin                // 一行发完: 第二行重走段表, 或结束
                            if (!r_chn) begin
                                r_chn <= 1'b1;
                                r_seg <= 4'd0;
                            end else begin
                                r_chn   <= 1'b0;
                                r_state <= S_IDLE;
                            end
                        end
                        default: begin
                            r_str_i <= 4'd0;
                            r_str_len <= str_len(r_seg);
                            r_state <= S_STR;
                            r_seg   <= r_seg + 1'b1;
                        end
                    endcase
                end
                // double-dabble: 40 拍, 每拍 BCD>=5 加 3 后整体左移进一位
                S_CONV: begin
                    r_b0  <= {w_a0[2:0],  r_val[39]};
                    r_b1  <= {w_a1[2:0],  w_a0[3]};
                    r_b2  <= {w_a2[2:0],  w_a1[3]};
                    r_b3  <= {w_a3[2:0],  w_a2[3]};
                    r_b4  <= {w_a4[2:0],  w_a3[3]};
                    r_b5  <= {w_a5[2:0],  w_a4[3]};
                    r_b6  <= {w_a6[2:0],  w_a5[3]};
                    r_b7  <= {w_a7[2:0],  w_a6[3]};
                    r_b8  <= {w_a8[2:0],  w_a7[3]};
                    r_b9  <= {w_a9[2:0],  w_a8[3]};
                    r_b10 <= {w_a10[2:0], w_a9[3]};
                    r_b11 <= {w_a11[2:0], w_a10[3]};
                    r_val <= {r_val[38:0], 1'b0};
                    if (r_ddi == 6'd39) begin
                        r_state <= S_CNT;
                    end else begin
                        r_ddi <= r_ddi + 1'b1;
                    end
                end
                // 有效位数 = 最高非零 BCD 位的位置(全零按 1 位, 打印 "0")
                S_CNT: begin
                    r_dcnt <= (r_b11 != 4'd0) ? 4'd12 :
                              (r_b10 != 4'd0) ? 4'd11 :
                              (r_b9  != 4'd0) ? 4'd10 :
                              (r_b8  != 4'd0) ? 4'd9  :
                              (r_b7  != 4'd0) ? 4'd8  :
                              (r_b6  != 4'd0) ? 4'd7  :
                              (r_b5  != 4'd0) ? 4'd6  :
                              (r_b4  != 4'd0) ? 4'd5  :
                              (r_b3  != 4'd0) ? 4'd4  :
                              (r_b2  != 4'd0) ? 4'd3  :
                              (r_b1  != 4'd0) ? 4'd2  : 4'd1;
                    r_send_i <= 4'd0;
                    r_state  <= S_SEND;
                end
                // 发送字符串: r_seg 已指向下一段, 当前段 = r_seg-1
                S_STR: begin
                    if (!w_tx_busy && !r_st_go) begin
                        r_tx_data <= str_rom(r_seg - 4'd1, r_str_i);
                        r_st_go   <= 1'b1;
                    end else if (r_st_go) begin
                        if (r_str_i == r_str_len - 4'd1) r_state <= S_SEG;
                        else r_str_i <= r_str_i + 1'b1;
                    end
                end
                // 从最高位到最低位发送数字(值 + '0' 转 ASCII)
                S_SEND: begin
                    if (!w_tx_busy && !r_st_go) begin
                        case (r_dcnt - 4'd1 - r_send_i)
                            4'd0:  r_tx_data <= 8'h30 + {4'd0, r_b0};
                            4'd1:  r_tx_data <= 8'h30 + {4'd0, r_b1};
                            4'd2:  r_tx_data <= 8'h30 + {4'd0, r_b2};
                            4'd3:  r_tx_data <= 8'h30 + {4'd0, r_b3};
                            4'd4:  r_tx_data <= 8'h30 + {4'd0, r_b4};
                            4'd5:  r_tx_data <= 8'h30 + {4'd0, r_b5};
                            4'd6:  r_tx_data <= 8'h30 + {4'd0, r_b6};
                            4'd7:  r_tx_data <= 8'h30 + {4'd0, r_b7};
                            4'd8:  r_tx_data <= 8'h30 + {4'd0, r_b8};
                            4'd9:  r_tx_data <= 8'h30 + {4'd0, r_b9};
                            4'd10: r_tx_data <= 8'h30 + {4'd0, r_b10};
                            default: r_tx_data <= 8'h30 + {4'd0, r_b11};
                        endcase
                        r_st_go <= 1'b1;
                    end else if (r_st_go) begin
                        if (r_send_i == r_dcnt - 4'd1) r_state <= S_SEG;
                        else r_send_i <= r_send_i + 1'b1;
                    end
                end
                default: r_state <= S_IDLE;
            endcase
        end
    end

endmodule
