// v25: two cascaded synchronous line memories, with explicit read/data alignment.
// Stage 0 reads the preceding row; stage 1 reads the row before that.
// No reset on RAM read registers: this is the vendor ERAM inference template.
// Output slot (x,y) contains the window centred on (max(x-1,0),max(y-1,0)).
// Coordinates, valid and frame-start all follow the same two-stage pipeline.
`timescale 1ns/1ps
module imgproc_win3x3 #(
    parameter IMG_W=1024, IMG_H=600, DW=24
) (
    input i_clk,i_rst_n,i_valid,input [DW-1:0] i_data,input i_frame_start,
    output o_valid,o_frame_start,o_center_x_odd,o_center_y_odd,
    output [DW-1:0] o_p00,o_p01,o_p02,o_p10,o_p11,o_p12,o_p20,o_p21,o_p22
);
    reg [DW-1:0] line1[0:IMG_W-1];
    reg [DW-1:0] line2[0:IMG_W-1];
    reg [DW-1:0] read1,read2;
    reg [10:0] next_x,next_y,x1,y1,x2,y2;
    reg v1,v2,fs1,fs2;
    reg [DW-1:0] cur1,cur2,previous2;
    wire [10:0] x=i_frame_start ? 11'd0 : next_x;
    wire [10:0] y=i_frame_start ? 11'd0 : next_y;

    // Nonblocking synchronous read before write, one clock per memory stage.
    // Separate memories avoid reading through a current-row bank-select mux.
    always @(posedge i_clk) if(i_valid) begin
        read1<=line1[x];
        line1[x]<=i_data;
    end
    always @(posedge i_clk) if(v1) begin
        read2<=line2[x1];
        line2[x1]<=read1;
    end

    wire [DW-1:0] up1=(y2!=0) ? previous2 : cur2;
    wire [DW-1:0] up2=(y2>=2) ? read2 : up1;
    reg [DW-1:0] a0,b0,a1,b1,a2,b2;
    wire [DW-1:0] left0=(x2==0) ? up2 : a0;
    wire [DW-1:0] left1=(x2==0) ? up1 : a1;
    wire [DW-1:0] left2=(x2==0) ? cur2 : a2;

    assign o_valid=v2;
    assign o_frame_start=v2 && fs2;
    assign o_center_x_odd=(x2!=0) && !x2[0];
    assign o_center_y_odd=(y2!=0) && !y2[0];
    assign o_p00=(x2==0) ? up2 : (x2==1) ? a0 : b0;
    assign o_p01=left0; assign o_p02=up2;
    assign o_p10=(x2==0) ? up1 : (x2==1) ? a1 : b1;
    assign o_p11=left1; assign o_p12=up1;
    assign o_p20=(x2==0) ? cur2 : (x2==1) ? a2 : b2;
    assign o_p21=left2; assign o_p22=cur2;

    always @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            next_x<=0;next_y<=0;x1<=0;y1<=0;x2<=0;y2<=0;
            v1<=0;v2<=0;fs1<=0;fs2<=0;
            cur1<=0;cur2<=0;previous2<=0;
            a0<=0;b0<=0;a1<=0;b1<=0;a2<=0;b2<=0;
        end else begin
            v1<=i_valid;v2<=v1;
            fs1<=i_valid && i_frame_start;fs2<=v1 && fs1;
            if(i_valid) begin
                cur1<=i_data;x1<=x;y1<=y;
                if(x==IMG_W-1) begin
                    next_x<=0;
                    next_y<=(y==IMG_H-1) ? 11'd0 : y+11'd1;
                end else begin next_x<=x+11'd1;next_y<=y;end
            end
            if(v1) begin cur2<=cur1;previous2<=read1;x2<=x1;y2<=y1;end
            // Shift the previous published column when the next output arrives.
            // This also preserves history across bubbles in i_valid.
            if(v2) begin
                a0<=up2;b0<=left0;
                a1<=up1;b1<=left1;
                a2<=cur2;b2<=left2;
            end
        end
    end
endmodule
