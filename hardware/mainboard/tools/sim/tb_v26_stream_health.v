`timescale 1ns/1ps
module tb_v26_stream_health;
reg clk=0,rst=0,v=0,sof=0,eof=0;always #5 clk=~clk;
reg [4:0] err=0;reg [31:0] fid=0;
wire fault;wire [31:0] count,badfid,badpixels;wire [5:0] history,last;wire [7:0] recovery;
cvp_stream_health #(.W(4),.H(2)) dut(.clk(clk),.rst_n(rst),.i_errors(err),
 .i_valid(v),.i_sof(sof),.i_eof(eof),.i_fid(fid),.o_fault(fault),.o_errors(count),
 .o_history(history),.o_last(last),.o_recovery(recovery),.o_bad_fid(badfid),.o_bad_pixels(badpixels));
integer errors=0,checks=0,j,b;reg [31:0] before_count;
task check;input condition;input [511:0] message;begin
 checks=checks+1;if(!condition)begin errors=errors+1;$display("FAIL %0s count=%0d fault=%b recovery=%h",message,count,fault,recovery);end
end endtask
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task frame;input integer n;input start_mark;input [4:0] last_error;begin
 fid=fid+1;
 for(j=0;j<n;j=j+1)begin
  v=1;sof=start_mark&&j==0;eof=j==n-1;err=j==n-1?last_error:0;tick();
  v=0;sof=0;eof=0;err=0;tick();
 end
end endtask
initial begin
 repeat(3)@(negedge clk);rst=1;
 frame(8,1,0);check(!fault&&count==0,"healthy startup never asserts fault");
 for(b=0;b<5;b=b+1)begin
  err=1<<b;tick();err=0;tick();before_count=count;
  check(fault&&last==(1<<b),"each input error has its own diagnosis");
  frame(8,1,0);check(fault,"frame containing prior error cannot recover");
  frame(8,1,0);check(fault&&recovery==3,"first clean frame remains quarantined");
  frame(8,1,0);check(!fault&&count==before_count,"second clean frame recovers, counter retained");
 end
 check(history==6'h1f,"historical masks survive recovery");
 frame(7,1,0);check(fault&&last==6'h20&&badpixels==7,"short output frame diagnosed");
 frame(8,1,0);check(fault,"one complete frame insufficient after short frame");
 frame(8,1,0);check(!fault,"two complete frames recover after short frame");
 frame(9,1,0);check(fault&&last==6'h20,"long output frame cannot recover");
 frame(8,0,0);check(fault&&last==6'h20,"EOF without SOF cannot recover");
 frame(8,1,0);frame(8,1,5'b10000);
 check(fault&&last==6'h10,"error at second clean EOF wins over recovery");
 frame(8,1,0);frame(8,1,0);check(!fault,"recovery restarts after colliding error");
 frame(8,1,5'b00010);frame(8,1,0);
 // A new SOF while a frame is incomplete must break consecutive-good counting.
 v=1;sof=1;eof=0;tick();sof=0;tick();v=0;tick();
 frame(8,1,0);check(fault&&last==6'h20,"interrupted frame prevents early recovery");
 frame(8,1,0);frame(8,1,0);check(!fault,"valid frames recover after interruption");
 before_count=count;
 repeat(4)frame(8,1,5'b00100);
 check(fault&&count==before_count+4,"persistent faults remain visible");
 rst=0;tick();check(!fault&&count==0&&history==0,"reset clears health history");
 if(errors==0)$display("TEST_RESULT PASS stream_health_transient_recovery_persistent_errors checks=%0d",checks);
 else $display("TEST_RESULT FAIL stream_health errors=%0d checks=%0d",errors,checks);
 $finish;
end
endmodule
