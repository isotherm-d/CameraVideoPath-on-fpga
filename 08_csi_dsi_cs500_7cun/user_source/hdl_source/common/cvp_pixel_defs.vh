// CVP_PIXEL_V1: real-time RGB888, valid separate, no camera backpressure.
`ifndef CVP_PIXEL_V1_DEFS
`define CVP_PIXEL_V1_DEFS
`define CVP_PIXEL_WIDTH 128
`define CVP_RGB 23:0
`define CVP_X 35:24
`define CVP_Y 47:36
`define CVP_FRAME_ID 79:48
`define CVP_CFG_ID 95:80
`define CVP_MODE 103:96
`define CVP_SOF 104
`define CVP_EOL 105
`define CVP_EOF 106
`define CVP_ERROR 107
`endif
