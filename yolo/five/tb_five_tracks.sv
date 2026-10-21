`timescale 1ns/1ps
module tb_five_tracks;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,commit=0,ready=0;reg [31:0] frame=1,source=1;reg [15:0] cfg=7,dcfg=7;
 reg [239:0] boxes={240{1'b1}};reg [14:0] classes=0;
 wire [239:0] ob;wire [14:0] oc;wire [4:0] known;wire rv;wire [31:0] rf;wire [7:0] rc;wire [63:0] rb;
 cvp_yolo_tracks dut(.clk(clk),.rst_n(rst),.i_commit(commit),.i_boxes(boxes),.i_classes(classes),.i_detect_frame(source),.i_frame(frame),.i_cfg(cfg),.i_detect_cfg(dcfg),.i_ticks(64'd12345),
 .o_boxes(ob),.o_classes(oc),.o_known(known),.o_result_valid(rv),.i_result_ready(ready),.o_result_frame(rf),.o_result_roi(),.o_result_class(rc),.o_result_bbox(rb),.o_result_tick());
 function [47:0] box(input integer i);
  box={12'(20+i*240),12'(80+i*100),12'(120+i*240),12'(180+i*100)};
 endfunction
 task detect(input integer f,reverse,missing,challenger);
  integer j,src;reg [239:0] before_boxes;reg [14:0] before_classes;reg [4:0] before_known;
  begin
   before_boxes=ob;before_classes=oc;before_known=known;
   @(negedge clk);source=f;frame=f+1;
   for(j=0;j<5;j=j+1)begin
    src=reverse?4-j:j;boxes[j*48+:48]=(src==missing)?48'hffffffffffff:box(src);
    classes[j*3+:3]=3'(src==2&&challenger>=0?challenger:src);
   end
   commit=1;@(negedge clk);commit=0;
   repeat(260)begin
    @(negedge clk);
    if(dut.pending && (ob!==before_boxes||oc!==before_classes||known!==before_known))
     $fatal(1,"partially updated display snapshot at source frame %0d state %0d",f,dut.state);
   end
  end
 endtask
 task hold_frame(input integer f);
  reg [239:0] before_boxes;reg [14:0] before_classes;reg [4:0] before_known;
  begin
   before_boxes=ob;before_classes=oc;before_known=known;
   @(negedge clk);frame=f;
   repeat(30)begin @(negedge clk);
    if(ob!==before_boxes||oc!==before_classes||known!==before_known)$fatal(1,"skipped video frame did not reuse display %0d",f);
   end
  end
 endtask
 reg [31:0] identity;reg [63:0] held_bbox;
 initial begin
  repeat(5)@(negedge clk);rst=1;
  detect(1,0,-1,-1);if(known!==0)$fatal(1,"first classification must wait for confirmation");
  identity=dut.tokens[2*32+:32];
  hold_frame(3);detect(3,1,-1,-1);
  if(known!==5'b11111)$fatal(1,"five types not confirmed %b",known);
  for(integer j=0;j<5;j=j+1)if(ob[j*48+:48]!==box(j)||oc[j*3+:3]!==3'(j))$fatal(1,"reordered identity/type mismatch %0d",j);
  if(!rv||rf!=1||rc!=0)$fatal(1,"diagnostic backpressure");held_bbox=rb;
  hold_frame(5);detect(5,0,-1,1);if(oc[8:6]!==2||known!==31||rb!==held_bbox)$fatal(1,"one bad result switched class");
  hold_frame(7);detect(7,1,-1,1);if(oc[8:6]!==2||known!==31)$fatal(1,"two bad results switched class");
  hold_frame(9);detect(9,0,-1,1);if(oc[8:6]!==1||known!==31)$fatal(1,"three results did not switch class");
  detect(11,1,2,-1);if(ob[2*48+:48]!==box(2)||!known[2]||oc[8:6]!==1)$fatal(1,"one missed scan flickered");
  hold_frame(13);detect(13,1,-1,-1);if(!known[2]||dut.tokens[2*32+:32]!==identity||oc[8:6]!==1)$fatal(1,"one missed scan lost identity");
  detect(15,0,-1,-1);detect(17,1,-1,-1);if(oc[8:6]!==2)$fatal(1,"recovery class confirmation");
  detect(19,0,2,-1);hold_frame(21);detect(21,1,2,-1);hold_frame(23);
  if(ob[2*48+:48]!==box(2)||!known[2]||oc[8:6]!==2)$fatal(1,"two missed scans flickered");
  detect(23,1,-1,-1);
  if(!known[2]||dut.tokens[2*32+:32]!==identity)$fatal(1,"two missed scans lost identity");
  detect(25,0,2,-1);detect(27,1,2,-1);detect(29,0,2,-1);
  if(ob[2*48+:48]!==48'hffffffffffff||known[2])$fatal(1,"third missed scan retained ghost box");
  detect(31,0,-1,-1);if(known[2]||dut.tokens[2*32+:32]===identity)$fatal(1,"retired target reused identity");
  detect(33,1,-1,-1);if(known!==31)$fatal(1,"reappeared target did not reconfirm");
  // Configuration changes hide old boxes immediately; a new generation confirms.
  @(negedge clk);cfg=8;if(ob!=={240{1'b1}})begin @(negedge clk);if(ob!=={240{1'b1}})$fatal(1,"stale config visible");end
  dcfg=8;detect(35,0,-1,-1);if(known!==0)$fatal(1,"new config reused old class");
  detect(37,1,-1,-1);if(known!==31)$fatal(1,"new config confirmation");
  hold_frame(39);
  @(negedge clk);frame=43;@(negedge clk);if(ob!=={240{1'b1}}||known!==0)$fatal(1,"stale detector boxes never expired");
  ready=1;repeat(3)@(negedge clk);if(rv)$fatal(1,"diagnostic handshake");
  $display("TEST_RESULT PASS tb_five_tracks 15Hz five types atomic snapshot skipped frames hold two missed scans third retires 2/3 confirmation cfg TTL backpressure");$finish;
 end
 initial begin #150000;$fatal(1,"timeout");end
endmodule
