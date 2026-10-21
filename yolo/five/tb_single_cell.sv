`timescale 1ns/1ps
module tb_single_cell;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,commit=0;reg [31:0] frame=1,source=1;reg [15:0] cfg=7;
 reg [239:0] boxes={240{1'b1}};reg [14:0] classes=0;
 wire [239:0] ob;wire [14:0] oc;wire [4:0] known;
 cvp_yolo_tracks #(.SINGLE_TARGET(1)) dut(.clk(clk),.rst_n(rst),.i_commit(commit),.i_boxes(boxes),.i_classes(classes),
  .i_detect_frame(source),.i_frame(frame),.i_cfg(cfg),.i_detect_cfg(cfg),.i_ticks(64'd0),.o_boxes(ob),.o_classes(oc),.o_known(known),
  .o_result_valid(),.i_result_ready(1'b1),.o_result_frame(),.o_result_roi(),.o_result_class(),.o_result_bbox(),.o_result_tick());
 function [47:0] box(input integer i,input integer nearer);
  if(i==1&&nearer)box={12'd610,12'd320,12'd670,12'd400};
  else box={12'(20+i*240),12'(80+i*100),12'(120+i*240),12'(180+i*100)};
 endfunction
 task detect(input integer f,reverse,missing,nearer);
  integer j,src;reg [239:0] oldb;reg [14:0] oldc;reg [4:0] oldk;
  begin
   oldb=ob;oldc=oc;oldk=known;
   @(negedge clk);source=f;frame=f+1;
   for(j=0;j<5;j=j+1)begin
    src=reverse?4-j:j;boxes[j*48+:48]=(missing==5||src==missing)?48'hffffffffffff:box(src,nearer);classes[j*3+:3]=3'(src);
   end
   commit=1;@(negedge clk);commit=0;
   repeat(300)begin @(negedge clk);
    if(dut.pending && (ob!==oldb||oc!==oldc||known!==oldk))$fatal(1,"partial selected display update");
   end
   if(ob[239:48]!=={192{1'b1}} || known[4:1]!==0)$fatal(1,"more than one cell visible");
  end
 endtask
 task selected(input integer cell_id,nearer,confirmed);
  if(ob[47:0]!==box(cell_id,nearer) || known[0]!==1'(confirmed) || (confirmed&&oc[2:0]!==3'(cell_id)))
   $fatal(1,"selected target/type mismatch id=%0d box=%h type=%0d known=%b",cell_id,ob[47:0],oc[2:0],known);
 endtask
 reg [31:0] identity;
 initial begin
  repeat(5)@(negedge clk);rst=1;
  detect(1,0,-1,0);selected(2,0,0);identity=dut.selected_token;
  detect(3,1,-1,0);selected(2,0,1);
  @(negedge clk);frame=5;repeat(30)@(negedge clk);selected(2,0,1);
  // A different target moves closer to center. It must not steal the lock.
  detect(5,0,-1,1);selected(2,0,1);
  detect(7,1,2,1);selected(2,0,1);
  detect(9,0,2,1);selected(2,0,1);
  detect(11,1,-1,1);selected(2,0,1);if(dut.selected_token!==identity)$fatal(1,"short misses lost selected identity");
  detect(13,0,2,1);detect(15,1,2,1);detect(17,0,2,1);selected(1,1,1);
  if(dut.selected_token===identity)$fatal(1,"third miss did not release selected identity");
  detect(19,0,5,1);selected(1,1,1);
  detect(21,1,5,1);selected(1,1,1);
  detect(23,0,5,1);if(ob!=={240{1'b1}}||known!==0)$fatal(1,"all missing retained ghost");
  detect(25,1,-1,0);selected(2,0,0);
  detect(27,0,-1,0);selected(2,0,1);
  @(negedge clk);cfg=8;@(negedge clk);if(ob!=={240{1'b1}}||known!==0)$fatal(1,"old config visible");
  detect(29,1,-1,1);selected(1,1,0);
  detect(31,0,-1,1);selected(1,1,1);
  @(negedge clk);frame=37;@(negedge clk);if(ob!=={240{1'b1}}||known!==0)$fatal(1,"stalled inference did not expire");
  $display("TEST_RESULT PASS tb_single_cell one box nearest center sticky identity reorder skipped frames two missed scans third retires config TTL atomic");$finish;
 end
 initial begin #150000;$fatal(1,"timeout");end
endmodule
