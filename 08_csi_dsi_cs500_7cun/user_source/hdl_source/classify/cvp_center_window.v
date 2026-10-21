// Consume precisely the centered square from the full display stream. Local
// detector counters advance only on these pixels; output boxes return to the
// full-frame coordinate system before OSD. Invalid sentinels stay invalid.
module cvp_center_window #(parameter N=5,W=1280,H=720,SIDE=640)(
 input i_valid,input [11:0] i_x,i_y,input [N*48-1:0] i_local_boxes,
 output o_valid,o_sof,o_eof,output wire [N*48-1:0] o_global_boxes
);
 localparam X0=(W-SIDE)/2,Y0=(H-SIDE)/2;
 assign o_valid=i_valid && i_x>=X0 && i_x<X0+SIDE && i_y>=Y0 && i_y<Y0+SIDE;
 assign o_sof=o_valid && i_x==X0 && i_y==Y0;
 assign o_eof=o_valid && i_x==X0+SIDE-1 && i_y==Y0+SIDE-1;
 genvar g;
 generate for(g=0;g<N;g=g+1)begin:G
  wire [47:0] b=i_local_boxes[g*48+:48];
  wire ok=b[47:36]<b[23:12] && b[35:24]<b[11:0] && b[23:12]<SIDE && b[11:0]<SIDE;
  wire [11:0] x0=b[47:36]+X0,y0=b[35:24]+Y0,x1=b[23:12]+X0,y1=b[11:0]+Y0;
  assign o_global_boxes[g*48+:48]=ok?{x0,y0,x1,y1}:48'hffffffffffff;
 end endgenerate
endmodule
