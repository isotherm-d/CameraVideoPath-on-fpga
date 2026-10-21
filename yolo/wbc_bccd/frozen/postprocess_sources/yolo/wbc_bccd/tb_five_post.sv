`timescale 1ns/1ps
module tb_five_post;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,start=0,abort=0,v=0,done=0;reg[3:0] x=0,y=0;reg[4:0] ch=0;reg signed[15:0] logit=0;
 wire busy,commit,overrun;wire[239:0] boxes;wire[14:0] classes;wire[79:0] scores;
 yolo160_boxes #(.SFILE("sigmoid.hex")) dut(.clk(clk),.rst_n(rst),.i_start(start),.i_abort(abort),.i_frame(32'd123),.i_cfg(16'd7),.i_valid(v),.i_x(x),.i_y(y),.i_channel(ch),.i_logit(logit),.i_done(done),
 .busy(busy),.commit(commit),.boxes(boxes),.classes(classes),.scores(scores),.frame_id(),.cfg_id(),.overrun(overrun));
 reg[15:0] vectors[0:17999];reg[239:0] expected[0:5];reg[14:0] expected_class[0:5];reg[79:0] expected_score[0:5];
 task begin_job;
  begin @(negedge clk);start=1;@(negedge clk);start=0;end
 endtask
 integer t,k;
 initial begin
  $readmemh("post_logits.hex",vectors);$readmemh("post_boxes.hex",expected);$readmemh("post_classes.hex",expected_class);$readmemh("post_scores.hex",expected_score);
  repeat(5)@(negedge clk);rst=1;
  for(t=0;t<6;t=t+1)begin
   begin_job();
   for(k=0;k<3000;k=k+1)begin
    @(negedge clk);v=1;ch=k%30;x=(k/30)%10;y=k/300;logit=vectors[t*3000+k];
    @(negedge clk);v=0;if(k%10==9)repeat(40)@(negedge clk);
   end
   @(negedge clk);done=1;@(negedge clk);done=0;
   wait(commit);@(negedge clk);
   if(overrun||boxes!==expected[t]||classes!==expected_class[t]||scores!==expected_score[t])$fatal(1,"post case%0d boxes%h/%h cls%h/%h score%h/%h",t,boxes,expected[t],classes,expected_class[t],scores,expected_score[t]);
  end
  begin_job();@(negedge clk);abort=1;@(negedge clk);abort=0;repeat(10)@(negedge clk);if(busy||commit)$fatal(1,"abort");
  begin_job();@(negedge clk);v=1;ch=9;logit=32767;
  @(negedge clk);ch=19;
  @(negedge clk);v=0;done=1;
  @(negedge clk);done=0;
  repeat(200)begin @(negedge clk);if(commit)$fatal(1,"overrun committed");end
  if(!overrun)$fatal(1,"missing overrun");
  $display("TEST_RESULT PASS tb_five_post all five classes ties top20 clipping full-width area NMS overrun abort high-objectness weak-class and background strong-class");$finish;
 end
 initial begin #1500000;$fatal(1,"timeout");end
endmodule
