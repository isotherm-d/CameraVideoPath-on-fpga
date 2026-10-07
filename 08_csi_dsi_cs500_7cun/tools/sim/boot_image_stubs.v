`timescale 1ns/1ps
// Image arithmetic is outside this camera-control test; no pixels are supplied.
module cvp_dpc #(parameter IMG_W=1280, IMG_H=720)(input i_clk,i_rst_n,i_valid,input [9:0] i_raw,input i_frame_start,output o_valid,output [9:0] o_raw,output o_frame_start);
assign o_valid=i_valid; assign o_raw=i_raw; assign o_frame_start=i_frame_start;
endmodule
module cvp_demosaic #(parameter IMG_W=1280, IMG_H=720)(input i_clk,i_rst_n,i_valid,input [9:0] i_raw,input i_frame_start,output o_valid,output [23:0] o_rgb,output o_frame_start);
assign o_valid=i_valid; assign o_rgb=24'd0; assign o_frame_start=i_frame_start;
endmodule
