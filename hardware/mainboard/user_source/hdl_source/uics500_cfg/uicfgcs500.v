// SC500CS register sequencer; original register/gain tables are preserved.
module uicfgcs500 #(
 parameter CLK_DIV=16'd999,STARTUP_CYCLES=1200000,SOFT_RESET_CYCLES=240000,
 parameter RETRY_CYCLES=24000,TIMEOUT_CYCLES=240000,MAX_RETRIES=2
)(
 input I_clk,I_rst_n,I_ae_req,input [15:0] I_ae,I_ag,
 output O_cam_scl,inout IO_cam_sda,
 output reg O_cfg_done,O_ae_cfg_done,output O_iic_error,output reg O_cfg_error,
 output [127:0] O_diagnostics
);
 localparam IDLE=0,PREPARE=1,REQUEST=2,WAIT_BUSY=3,WAIT_DONE=4,GAP=5,RECOVER=6,FAILED=7;
 reg [2:0] TS_S;reg [20:0] timer,startup;reg startup_done;
 reg [8:0] reg_index;reg [1:0] table_kind;reg boot_complete;
 reg iic_req,attempt_error,runtime_error;reg [31:0] wr_data;
 reg [15:0] held_ae,held_ag;reg [3:0] attempts;
 reg [15:0] init_errors,retries,runtime_nacks,runtime_timeouts,last_register;
 reg [7:0] last_byte,last_code;reg last_init;
 wire iic_busy,bus_error;wire [2:0] error_byte;wire [23:0] REG_DATA_REG,REG_DATA_AE;
 wire [8:0] REG_SIZE_REG,REG_SIZE_AE;wire [15:0] gain_value;
 wire [23:0] REG_DATA=table_kind==0?REG_DATA_REG:REG_DATA_AE;
 wire [8:0] REG_SIZE=table_kind==0?REG_SIZE_REG:REG_SIZE_AE;
 wire engine_reset=I_rst_n&&startup_done&&TS_S!=RECOVER;
 assign O_iic_error=runtime_error;
 wire [7:0] diag_flags={1'b0,last_init,(!boot_complete&&!O_cfg_error),
                       (init_errors!=0&&boot_complete&&!O_cfg_error),boot_complete,
                       (runtime_error&&last_code==2),runtime_error,O_cfg_error};
 assign O_diagnostics={init_errors,retries,runtime_nacks,runtime_timeouts,last_register,last_byte,last_code,diag_flags,24'd0};
 function [15:0] inc;input [15:0] n;begin inc=n==65535?n:n+1'b1;end endfunction
 always @(posedge I_clk or negedge I_rst_n)begin
  if(!I_rst_n)begin
   startup<=0;startup_done<=0;TS_S<=PREPARE;timer<=0;reg_index<=0;table_kind<=0;boot_complete<=0;
   iic_req<=0;attempt_error<=0;runtime_error<=0;wr_data<=0;held_ae<=500;held_ag<=108;attempts<=0;
   O_cfg_done<=0;O_ae_cfg_done<=0;O_cfg_error<=0;
   init_errors<=0;retries<=0;runtime_nacks<=0;runtime_timeouts<=0;last_register<=0;last_byte<=0;last_code<=0;last_init<=0;
  end else if(!startup_done)begin
   held_ae<=I_ae;held_ag<=I_ag;
   if(startup>=STARTUP_CYCLES-1)startup_done<=1;else startup<=startup+1'b1;
  end else begin
   if(bus_error)attempt_error<=1;
   case(TS_S)
    IDLE:if(I_ae_req&&boot_complete)begin
     held_ae<=I_ae;held_ag<=I_ag;reg_index<=0;table_kind<=2;O_ae_cfg_done<=0;runtime_error<=0;attempts<=0;TS_S<=PREPARE;
    end
    PREPARE:if(reg_index==REG_SIZE)begin
     reg_index<=0;
     if(table_kind==0)begin O_cfg_done<=1;table_kind<=1;end
     else begin O_ae_cfg_done<=1;boot_complete<=1;TS_S<=IDLE;end
    end else if(!iic_busy)begin
     wr_data<={REG_DATA[7:0],REG_DATA[15:8],REG_DATA[23:16],8'h6c};attempt_error<=0;timer<=0;TS_S<=REQUEST;
    end
    REQUEST:begin iic_req<=1;timer<=0;TS_S<=WAIT_BUSY;end
    WAIT_BUSY:begin
     timer<=timer+1'b1;
     if(iic_busy)begin iic_req<=0;TS_S<=WAIT_DONE;end
     else if(timer==TIMEOUT_CYCLES-1)begin iic_req<=0;TS_S<=WAIT_DONE;timer<=TIMEOUT_CYCLES;attempt_error<=1;end
    end
    WAIT_DONE:begin
     timer<=timer+1'b1;
     if(!iic_busy||timer>=TIMEOUT_CYCLES)begin
      iic_req<=0;
      if(attempt_error||bus_error||timer>=TIMEOUT_CYCLES)begin
       last_register<=REG_DATA[23:8];last_byte<=timer>=TIMEOUT_CYCLES?0:{5'd0,error_byte};last_code<=timer>=TIMEOUT_CYCLES?2:1;last_init<=table_kind!=2;
       if(table_kind!=2)init_errors<=inc(init_errors);
       else if(timer>=TIMEOUT_CYCLES)runtime_timeouts<=inc(runtime_timeouts);else runtime_nacks<=inc(runtime_nacks);
       if(attempts<MAX_RETRIES)begin
        attempts<=attempts+1'b1;if(table_kind!=2)retries<=inc(retries);timer<=0;TS_S<=RECOVER;
       end else if(table_kind!=2)begin O_cfg_error<=1;TS_S<=FAILED;end
       else begin runtime_error<=1;O_ae_cfg_done<=1;TS_S<=IDLE;end
      end else begin
       attempts<=0;reg_index<=reg_index+1'b1;
       if(table_kind==0&&reg_index==0)begin timer<=0;TS_S<=GAP;end else TS_S<=PREPARE;
      end
     end
    end
    GAP:if(timer>=SOFT_RESET_CYCLES-1)TS_S<=PREPARE;else timer<=timer+1'b1;
    RECOVER:if(timer>=RETRY_CYCLES-1)begin TS_S<=PREPARE;attempt_error<=0;end else timer<=timer+1'b1;
    FAILED:iic_req<=0;
    default:TS_S<=FAILED;
   endcase
  end
 end
 uii2c #(.WMEN_LEN(4),.RMEN_LEN(1),.CLK_DIV(CLK_DIV)) uii2c_inst(
 .I_clk(I_clk),.I_rstn(engine_reset),.O_iic_scl(O_cam_scl),.IO_iic_sda(IO_cam_sda),
 .I_wr_data(wr_data),.I_wr_cnt(8'd4),.O_rd_data(),.I_rd_cnt(8'd0),.I_iic_mode(1'b0),.I_iic_req(iic_req),
 .O_iic_bus_error(bus_error),.O_error_byte(error_byte),.O_iic_busy(iic_busy),.IO_iic_sda_dg());
 uics500reg uics500reg_inst(.REG_SIZE(REG_SIZE_REG),.REG_INDEX(reg_index),.REG_DATA(REG_DATA_REG));
 SC500GainTbl gain_tbl(.I_clk(I_clk),.I_rstn(!I_rst_n),.I(held_ag-16),.O(gain_value));
 uics500regAE uics500regAE_inst(.REG_SIZE(REG_SIZE_AE),.REG_INDEX(reg_index),.REG_DATA(REG_DATA_AE),.I_AG(gain_value),.I_AE(held_ae));
endmodule
