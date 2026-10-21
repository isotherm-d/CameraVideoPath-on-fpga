`timescale 1ns/1ps
/* cvp_cmd_rx TB: 产生 RGMII 时序命令帧, 校验 o_mode/o_net_ae/o_gain_* 寄存器 */
module tb_cmd_rx;

    reg rxclk = 0;
    reg rst_n_rx = 0;
    reg clk100 = 0;
    reg rst_n_100 = 0;
    always #4 rxclk = ~rxclk;      // 125MHz
    always #8 clk100 = ~clk100;    // ~62.5M(减半以观察跨域)

    reg [3:0] rxd = 0;
    reg rxctl = 0;

    wire [1:0] o_mode;
    wire [15:0] o_net_ae;
    wire [8:0] o_gain_r, o_gain_g, o_gain_b;
    wire o_swap;

    cvp_cmd_rx dut (
        .I_rxclk(rxclk), .I_rst_n_rx(rst_n_rx),
        .I_rxd(rxd), .I_rxctl(rxctl),
        .I_rst_n_gmii(rst_n_100), .I_clk_gmii(clk100),
        .I_clk100(clk100), .I_rst_n_100(rst_n_100),
        .o_mode(o_mode), .o_net_ae(o_net_ae),
        .o_gain_r(o_gain_r), .o_gain_g(o_gain_g), .o_gain_b(o_gain_b),
        .o_swap(o_swap)
    );

    /* RGMII 发送: posedge 发低 nibble, negedge 发高 nibble */
    task send_byte(input [7:0] b);
        begin
            rxd  = b[3:0];  rxctl = 1'b1;   @(posedge rxclk);
            #2;
            rxd  = b[7:4];                   @(negedge rxclk);
        end
    endtask

    task send_idle(input integer n);
        begin
            rxctl = 1'b0;
            repeat (n) begin
                rxd = 4'h5; @(posedge rxclk); #2; rxd = 4'h5; @(negedge rxclk);
            end
        end
    endtask

    /* 发一个完整命令帧 */
    task send_cmd(input [7:0] cmd, input [23:0] val);
        integer i;
        reg [7:0] fb [0:61];
        begin
            fb[0]=8'h55; fb[1]=8'h55; fb[2]=8'h55; fb[3]=8'h55;
            fb[4]=8'h55; fb[5]=8'h55; fb[6]=8'h55; fb[7]=8'hD5;
            fb[8]=8'hFF; fb[9]=8'hFF; fb[10]=8'hFF; fb[11]=8'hFF;
            fb[12]=8'hFF; fb[13]=8'hFF;
            fb[14]=8'h11; fb[15]=8'h22; fb[16]=8'h33; fb[17]=8'h44;
            fb[18]=8'h55; fb[19]=8'h66;
            fb[20]=8'h08; fb[21]=8'h00;
            for (i = 22; i <= 41; i = i + 1) fb[i] = 8'h00;
            fb[30] = 8'h11;                     // IP 协议 = UDP
            fb[42]=8'h0F; fb[43]=8'hA0;         // UDP 源端口 4000
            fb[44]=8'h17; fb[45]=8'h71;         // UDP 目的端口 6001
            fb[46]=8'h00; fb[47]=8'h10;         // UDP 长度 16
            fb[48]=8'h00; fb[49]=8'h00;         // UDP 校验和 0
            fb[50]=8'hC5; fb[51]=8'hA5; fb[52]=8'h50; fb[53]=8'h01;  // 魔数
            fb[54]=cmd;                          // 命令
            fb[55]=val[23:16]; fb[56]=val[15:8]; fb[57]=val[7:0];    // 值
            fb[58]=8'hDE; fb[59]=8'hAD; fb[60]=8'hBE; fb[61]=8'hEF;  // FCS
            for (i = 0; i <= 61; i = i + 1) send_byte(fb[i]);
        end
    endtask

    integer errors = 0;

    initial begin
        rst_n_rx = 0; rst_n_100 = 0;
        #100;
        rst_n_rx = 1; rst_n_100 = 1;
        #200;

        // 命令 1: 模式 2(网络), 命令 1: 曝光码 1400
        send_idle(10);
        send_cmd(8'd0, 24'd2);
        send_idle(20);
        send_cmd(8'd1, 24'd1400);
        send_idle(20);

        // 等 100M 域应用
        #50000;
        if (o_mode !== 2'd2) begin $display("FAIL: o_mode=%d 期望 2", o_mode); errors = errors + 1; end
        else $display("PASS: o_mode=2");
        if (o_net_ae !== 16'd1400) begin $display("FAIL: o_net_ae=%d 期望 1400", o_net_ae); errors = errors + 1; end
        else $display("PASS: o_net_ae=1400");

        // 命令 2/3/4: 白平衡增益 R=291 G=256 B=246 + swap
        send_cmd(8'd2, 24'd291);
        send_idle(20);
        send_cmd(8'd3, 24'd256);
        send_idle(20);
        send_cmd(8'd4, 24'd246);
        send_idle(20);
        send_cmd(8'd5, 24'd1);
        send_idle(20);
        #50000;
        if (o_gain_r !== 9'd291) begin $display("FAIL: gain_r=%d 期望 291", o_gain_r); errors = errors + 1; end
        else $display("PASS: gain_r=291");
        if (o_gain_g !== 9'd256) begin $display("FAIL: gain_g=%d 期望 256", o_gain_g); errors = errors + 1; end
        else $display("PASS: gain_g=256");
        if (o_gain_b !== 9'd246) begin $display("FAIL: gain_b=%d 期望 246", o_gain_b); errors = errors + 1; end
        else $display("PASS: gain_b=246");
        if (o_swap !== 1'b1) begin $display("FAIL: swap=%d 期望 1", o_swap); errors = errors + 1; end
        else $display("PASS: swap=1");

        // 负例: 魔数错帧不改变寄存器
        send_cmd_with_bad_magic(8'd1, 24'd999);
        send_idle(20);
        #50000;
        if (o_net_ae !== 16'd1400) begin $display("FAIL: 负例改变了 o_net_ae=%d", o_net_ae); errors = errors + 1; end
        else $display("PASS: 负例(魔数错)未影响寄存器");

        if (errors == 0) $display("=== TB ALL PASS ===");
        else $display("=== TB FAILED: %d errors ===", errors);
        $finish;
    end

    task send_cmd_with_bad_magic(input [7:0] cmd, input [23:0] val);
        integer i;
        reg [7:0] fb [0:61];
        begin
            fb[0]=8'h55; fb[1]=8'h55; fb[2]=8'h55; fb[3]=8'h55;
            fb[4]=8'h55; fb[5]=8'h55; fb[6]=8'h55; fb[7]=8'hD5;
            for (i = 8; i <= 41; i = i + 1) fb[i] = 8'h00;
            fb[30] = 8'h11;
            fb[44]=8'h17; fb[45]=8'h71;
            fb[50]=8'hDE; fb[51]=8'hAD; fb[52]=8'hBE; fb[53]=8'hEF;  // 魔数错
            fb[54]=cmd; fb[55]=val[23:16]; fb[56]=val[15:8]; fb[57]=val[7:0];
            for (i = 0; i <= 61; i = i + 1) send_byte(fb[i]);
        end
    endtask

endmodule
