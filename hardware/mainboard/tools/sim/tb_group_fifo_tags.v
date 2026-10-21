`timescale 1ns/1ps
module tb_group_fifo_tags;
reg wc=0,rc=0,rst=0,wv=0,wu=0,wl=0;
always #12.5 wc=~wc;
always #5 rc=~rc;
reg [39:0] wd=0;
wire rv,ru,rl;
wire [39:0] rd;
integer i,count=0,errors=0;
group_fifo dut(.I_wr_clk(wc),.I_wr_rst_n(rst),.I_wr_valid(wv),.I_wr_data(wd),.I_wr_tuser(wu),.I_wr_tlast(wl),.I_rd_clk(rc),.I_rd_rst_n(rst),.O_rd_valid(rv),.O_rd_data(rd),.O_rd_tuser(ru),.O_rd_tlast(rl));
always @(negedge rc)if(rv)begin
 if(rd!==count+1024 || ru!==(count%32==0) || rl!==(count%8==7))begin
  if(errors<6)$display("FAIL: word=%0d data=%0d SOF=%b EOL=%b",count,rd,ru,rl);
  errors=errors+1;
 end
 count=count+1;
end
initial begin
 #100;rst=1;
 for(i=0;i<64;i=i+1)begin
  @(negedge wc);wv=1;wd=i+1024;wu=(i%32==0);wl=(i%8==7);
  @(negedge wc);wv=0;wu=0;wl=0;
 end
 repeat(160)@(negedge rc);
 if(errors==0 && count==64)$display("TEST_RESULT PASS group_fifo_frame_line_tags");
 else $display("TEST_RESULT FAIL group_fifo_tags errors=%0d words=%0d",errors,count);
 $finish;
end
endmodule
