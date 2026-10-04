`timescale 1ns / 1ns
/*****************************************************************
 pack_4 —— 1 像素/拍 RGB888 → 96bit 组(4 像素/拍)攒包器
 整合 cvp ISP(v13): cvp_proc/cvp_awb 输出单像素流, 下游(网口 eth_dbg 的
 96bit 输入 / data_96bit_to_128bit)吃 4 像素组。帧首像素强制对齐组边界
 (IMG_W 为 4 的倍数时组与图像 4 像素列天然对齐)。
 位序与 AWB 观测口语义一致: [95:72]=像素0(最先), [71:48]=1, [47:24]=2, [23:0]=3。
*****************************************************************/
module pack_4 (
    input          I_clk,
    input          I_rst_n,

    input          I_valid,        // 1 像素/拍
    input  [23:0]  I_rgb,
    input          I_frame_start,  // 帧首像素标记(与 I_valid 同拍)

    output reg         O_tvalid,   // 组有效
    output reg  [95:0] O_tdata,    // 4 像素组
    output reg         O_tuser     // 帧首组标记
);

    reg [23:0] r_px0, r_px1, r_px2;
    reg [1:0]  r_cnt;
    reg        r_fs_pending;       // 本组含帧首像素

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_cnt       <= 2'd0;
            r_px0 <= 24'd0; r_px1 <= 24'd0; r_px2 <= 24'd0;
            r_fs_pending<= 1'b0;
            O_tvalid <= 1'b0;
            O_tdata  <= 96'd0;
            O_tuser  <= 1'b0;
        end else begin
            O_tvalid <= 1'b0;
            O_tuser  <= 1'b0;
            if (I_valid) begin
                if (I_frame_start) begin
                    // 帧首像素: 强制从组槽 0 重新开始
                    r_cnt        <= 2'd1;
                    r_px0        <= I_rgb;
                    r_fs_pending <= 1'b1;
                end else begin
                    case (r_cnt)
                        2'd0: begin r_px0 <= I_rgb; r_cnt <= 2'd1; end
                        2'd1: begin r_px1 <= I_rgb; r_cnt <= 2'd2; end
                        2'd2: begin r_px2 <= I_rgb; r_cnt <= 2'd3; end
                        default: begin
                            // 本拍是组内第 4 个像素: 输出 {px3, px2, px1, px0}
                            O_tdata  <= {I_rgb, r_px2, r_px1, r_px0};
                            O_tvalid <= 1'b1;
                            O_tuser  <= r_fs_pending;
                            r_fs_pending <= 1'b0;
                            r_cnt <= 2'd0;
                        end
                    endcase
                end
            end
        end
    end

endmodule
