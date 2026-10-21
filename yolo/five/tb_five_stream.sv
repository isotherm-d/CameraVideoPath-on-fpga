`timescale 1ns/1ps
module tb_five_stream #(parameter PIXEL_GAP=1,ROW_GAP=0);
 reg clk=0;always #5 clk=~clk;
 reg rst=0,v=0,sof=0;reg[11:0] x=0,y=0;reg[23:0] rgb=0;reg[31:0] frame=0;
 wire[239:0] b3,b2,ob;wire[14:0] c3,c2,oc;wire[79:0] s3,s2;
 wire commit3,commit2;wire[31:0] f3,f2,a3,a2;wire[15:0] g3,g2;wire[4:0] known;
 cvp_yolo160_detector #(.FRAME_INTERVAL(3)) d3(.clk(clk),.rst_n(rst),.i_valid(v),.i_x(x),.i_y(y),.i_rgb(rgb),.i_frame(frame),.i_cfg(16'd7),.o_boxes(b3),.o_classes(c3),.o_scores(s3),.o_commit(commit3),.o_frame(f3),.o_cfg(g3),.o_busy(),.o_aborts(a3));
 cvp_yolo160_detector #(.FRAME_INTERVAL(2)) d2(.clk(clk),.rst_n(rst),.i_valid(v),.i_x(x),.i_y(y),.i_rgb(rgb),.i_frame(frame),.i_cfg(16'd7),.o_boxes(b2),.o_classes(c2),.o_scores(s2),.o_commit(commit2),.o_frame(f2),.o_cfg(g2),.o_busy(),.o_aborts(a2));
 defparam d3.first.WFILE="first8.hex",d2.first.WFILE="first8.hex";
 defparam d3.core.W4FILE="weights4.hex",d3.core.HFILE="head8.hex",d3.core.MFILE="meta.hex";
 defparam d2.core.W4FILE="weights4.hex",d2.core.HFILE="head8.hex",d2.core.MFILE="meta.hex";
 defparam d3.post.SFILE="sigmoid.hex",d2.post.SFILE="sigmoid.hex";
 wire rv;wire[31:0] rf;wire[7:0] rc;
 cvp_yolo_tracks #(.SINGLE_TARGET(1)) tracks(.clk(clk),.rst_n(rst),.i_commit(commit2),.i_boxes(b2),.i_classes(c2),.i_detect_frame(f2),.i_frame(frame),.i_cfg(16'd7),.i_detect_cfg(g2),.i_ticks(64'd123),
 .o_boxes(ob),.o_classes(oc),.o_known(known),.o_result_valid(rv),.i_result_ready(1'b1),.o_result_frame(rf),.o_result_roi(),.o_result_class(rc),.o_result_bbox(),.o_result_tick());
 wire ov,os;wire[23:0] orgb;wire[31:0] oframe;
 cvp_cell_label #(.N(1),.FULL_NAMES(1)) label(.clk(clk),.rst_n(rst),.i_valid(v),.i_sof(sof),.i_rgb(rgb),.i_x(x),.i_y(y),.i_frame(frame),.i_sw1_n(1'b1),.i_boxes(ob[47:0]),.i_classes(oc[2:0]),.i_known(known[0]),.o_valid(ov),.o_sof(os),.o_rgb(orgb),.o_frame(oframe));
 reg[23:0] image[0:25599];reg[239:0] gb[0:0];reg[14:0] gc[0:0];reg[79:0] gs[0:0];
 reg[2:0] qv=0,qs=0;reg[31:0] qframe[0:2];reg[11:0] qx[0:2],qy[0:2];
 integer cycles=0,n3=0,n2=0,start3=0,start2=0,max3=0,max2=0,border_pixels=0,type_pixels=0,descriptors=0;
 reg[4:0] expected_known=0;
 integer frame_border[1:6],frame_type[1:6];
 always @(posedge clk)if(rst)begin
  cycles=cycles+1;
  if(d3.first.capture_start)start3=cycles;
  if(d2.first.capture_start)start2=cycles;
  if(commit3)begin
   if(f3!==32'(1+3*n3)||g3!=7||b3!==gb[0]||c3!==gc[0]||s3!==gs[0])$fatal(1,"10Hz YOLO frame/type/box mismatch");
   if(cycles-start3>max3)max3=cycles-start3;n3=n3+1;
  end
  if(commit2)begin
   if(f2!==32'(1+2*n2)||g2!=7||b2!==gb[0]||c2!==gc[0]||s2!==gs[0])$fatal(1,"15Hz YOLO frame/type/box mismatch");
   if(cycles-start2>max2)max2=cycles-start2;n2=n2+1;
  end
  if(a3||a2)$fatal(1,"detector abort at720p30");
  if(rv)begin if(rc>=5||!(rf==1||rf==3||rf==5))$fatal(1,"raw YOLO descriptor");descriptors=descriptors+1;end
  if(frame>=3 && ob!==gb[0])$fatal(1,"display flickered between 15Hz transactions on frame %0d",frame);
  if(frame>=5 && known!==expected_known)$fatal(1,"confirmed type flickered between inferences");
  if(ov!==qv[2])$fatal(1,"OSD valid alignment");
  if(ov)begin
   if(os!==qs[2]||oframe!==qframe[2])$fatal(1,"OSD metadata alignment");
   if(qx[2]==label.bx0[0] && qy[2]==label.by0[0]+20)begin
    if(orgb!==24'h00ff00)$fatal(1,"green box border absent");border_pixels=border_pixels+1;frame_border[qframe[2]]=frame_border[qframe[2]]+1;
   end
   if(orgb==24'h00ffff && qx[2]>=label.bx0[0] && qx[2]<label.bx0[0]+160 && qy[2]>=label.by0[0]-16 && qy[2]<label.by0[0])begin type_pixels=type_pixels+1;frame_type[qframe[2]]=frame_type[qframe[2]]+1;end
  end
  qv<={qv[1:0],v};qs<={qs[1:0],sof};qframe[0]<=frame;qx[0]<=x;qy[0]<=y;
  for(integer z=1;z<3;z=z+1)begin qframe[z]<=qframe[z-1];qx[z]<=qx[z-1];qy[z]<=qy[z-1];end
 end
 initial begin
  $readmemh("rgb.hex",image);$readmemh("expected_boxes.hex",gb);$readmemh("expected_classes.hex",gc);$readmemh("expected_scores.hex",gs);
  for(integer j=1;j<=6;j=j+1)begin frame_border[j]=0;frame_type[j]=0;end
  for(integer k=0;k<5;k=k+1)expected_known[k]=gb[0][k*48+:48]!=48'hffffffffffff;
  if(expected_known!==5'b00001)$fatal(1,"stream vector must contain exactly one detected cell for the independent pixel reference");
  repeat(8)@(negedge clk);rst=1;
  for(integer f=1;f<=6;f=f+1)begin
   for(integer p=0;p<921600;p=p+1)begin
    @(negedge clk);frame=f;v=1;sof=p==0;x=p%1280;y=p/1280;rgb=image[(y*2/9)*160+(x/8)];
    if(PIXEL_GAP>1)begin @(negedge clk);v=0;sof=0;repeat(PIXEL_GAP-2)@(negedge clk);end
    if(p%1280==1279&&ROW_GAP>0)begin @(negedge clk);v=0;sof=0;repeat(ROW_GAP-1)@(negedge clk);end
   end
   @(negedge clk);v=0;sof=0;repeat(3333332-921600*PIXEL_GAP-720*ROW_GAP)@(negedge clk);
  end
  repeat(2000000)@(negedge clk);
  if(n3!=2||n2!=3||known!==expected_known||ob!==gb[0])$fatal(1,"joint stream counts/boxes/known %0d/%0d %b/%b",n3,n2,known,expected_known);
  for(integer k=0;k<5;k=k+1)if(expected_known[k]&&oc[k*3+:3]!==gc[0][k*3+:3])$fatal(1,"per-box YOLO class association %0d",k);
  if(border_pixels<3||type_pixels==0||descriptors==0)$fatal(1,"board output missing %0d/%0d",border_pixels,type_pixels);
  for(integer j=3;j<=6;j=j+1)if(frame_border[j]==0)$fatal(1,"box missing from displayed video frame %0d",j);
  if(frame_type[5]==0||frame_type[6]==0)$fatal(1,"type missing from adjacent inference/skipped video frames");
  if(max3>=6666666||max2>=6666666)$fatal(1,"15Hz deadline missed");
  $display("TEST_RESULT PASS tb_five_stream six full720p30 frames YOLO10Hz=%0d YOLO15Hz=%0d latency_cycles=%0d/%0d border=%0d type_pixels=%0d descriptors=%0d no CellNet",n3,n2,max3,max2,border_pixels,type_pixels,descriptors);$finish;
 end
 initial begin #240000000;$fatal(1,"timeout");end
endmodule
