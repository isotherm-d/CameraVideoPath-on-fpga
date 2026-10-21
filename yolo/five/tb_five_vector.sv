`timescale 1ns/1ps
module tb_five_vector #(parameter L7_WORDS=300,L8_WORDS=500);
 reg clk=0;always #5 clk=~clk;
 reg rst=0,v=0;reg[11:0] x=0,y=0;reg[23:0] rgb=0;
 wire busy,done,aborted,we,cd;wire[12:0] addr;wire[31:0] data,frame;wire[15:0] cfg;
 wire lv,ld;wire[3:0] lx,ly,layer;wire[4:0] lc;wire signed[15:0] logit;
 wire pc,pe;wire[239:0] boxes;wire[14:0] classes;wire[79:0] scores;
 yolo160_first #(.FULL_FRAME(1),.WFILE("first8.hex")) first(.clk(clk),.rst_n(rst),.i_enable(!busy),.i_valid(v),.i_x(x),.i_y(y),.i_rgb(rgb),.i_frame(32'd1),.i_cfg(16'd7),.busy(),.done(cd),.aborted(aborted),.we(we),.addr(addr),.data(data),.frame_id(frame),.cfg_id(cfg));
 yolo160_core #(.W4FILE("weights4.hex"),.HFILE("head8.hex"),.MFILE("meta.hex")) core(.clk(clk),.rst_n(rst),.i_we(we),.i_addr(addr),.i_data(data),.i_start(cd),.i_abort(aborted),.busy(busy),.done(done),.logit_valid(lv),.logit_x(lx),.logit_y(ly),.logit_channel(lc),.logit(logit),.layer_done(ld),.layer(layer));
 yolo160_boxes #(.SFILE("sigmoid.hex")) post(.clk(clk),.rst_n(rst),.i_start(cd),.i_abort(aborted),.i_frame(frame),.i_cfg(cfg),.i_valid(lv),.i_x(lx),.i_y(ly),.i_channel(lc),.i_logit(logit),.i_done(done),.busy(),.commit(pc),.boxes(boxes),.classes(classes),.scores(scores),.frame_id(),.cfg_id(),.overrun(pe));
 reg[23:0] image[0:25599];reg[31:0] g0[0:6399],g1[0:1599],g2[0:399],g3[0:199],g4[0:299],g5[0:499],g6[0:999],g7[0:L7_WORDS-1],g8[0:L8_WORDS-1];
 reg[15:0] gold[0:2999];reg[239:0] gb[0:0];reg[14:0] gc[0:0];reg[79:0] gs[0:0];
 integer cycles=0,c0=0,c9=0;reg[31:0] expected;
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>6000000)$fatal(1,"timeout layer%0d state%0d",layer,core.state);
  if(aborted)$fatal(1,"capture aborted");
  if(we)begin if(addr!==13'(c0)||data!==g0[c0])$fatal(1,"C1 addr%0d expected%0d data%h/%h",addr,c0,data,g0[c0]);c0=c0+1;end
  if(core.state==10)begin
   case(layer)
    1:expected=g1[core.outptr];2:expected=g2[core.outptr];3:expected=g3[core.outptr];4:expected=g4[core.outptr];
    5:expected=g5[core.outptr];6:expected=g6[core.outptr];7:expected=g7[core.outptr];8:expected=g8[core.outptr];default:expected='x;
   endcase
   if(core.quant_word!==expected)$fatal(1,"layer%0d addr%0d actual%h expected%h",layer,core.outptr,core.quant_word,expected);
  end
  if(lv)begin
   if(logit!==gold[c9]||lx!==4'((c9/30)%10)||ly!==4'(c9/300)||lc!==5'(c9%30))$fatal(1,"logit%0d actual%h expected%h xy%0d/%0d ch%0d",c9,logit,gold[c9],lx,ly,lc);
   c9=c9+1;
  end
  if(pc)begin
   if(c0!=6400||c9!=3000||pe||boxes!==gb[0]||classes!==gc[0]||scores!==gs[0])$fatal(1,"final mismatch boxes%h/%h classes%h/%h scores%h/%h counts%0d/%0d overrun%0d",boxes,gb[0],classes,gc[0],scores,gs[0],c0,c9,pe);
   $display("TEST_RESULT PASS tb_five_vector ten integer layers exact logits=%0d first_words=%0d cycles=%0d boxes/classes/confidences exact",c9,c0,cycles);$finish;
  end
 end
 initial begin
  $readmemh("rgb.hex",image);$readmemh("layer0.hex",g0);$readmemh("layer1.hex",g1);$readmemh("layer2.hex",g2);$readmemh("layer3.hex",g3);
  $readmemh("layer4.hex",g4);$readmemh("layer5.hex",g5);$readmemh("layer6.hex",g6);$readmemh("layer7.hex",g7);$readmemh("layer8.hex",g8);$readmemh("logits.hex",gold);
  $readmemh("expected_boxes.hex",gb);$readmemh("expected_classes.hex",gc);$readmemh("expected_scores.hex",gs);
  repeat(8)@(negedge clk);rst=1;
  for(integer b=0;b<160;b=b+1)begin
   for(integer a=0;a<160;a=a+1)begin
    @(negedge clk);v=1;x=4+8*a;y=2+4*b+b/2;rgb=image[b*160+a];
    @(negedge clk);v=0;repeat(2)@(negedge clk);
   end
   repeat(4480)@(negedge clk);
  end
 end
endmodule
