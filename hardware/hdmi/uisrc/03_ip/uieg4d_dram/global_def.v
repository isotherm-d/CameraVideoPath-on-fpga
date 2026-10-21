

`define   ROW_WIDTH             12
`define   BA_WIDTH              2
`define   COL_WIDTH             9
`define   DATA_WIDTH            16 
`define   ADDR_WIDTH            23 //ROW_WIDTH+BA_WIDTH+COL_WIDTH
`define   DM_WIDTH              2

`define CMD_INHIBIT             3'b111
`define CMD_NOP                 3'b111
`define CMD_ACTIVE              3'b011
`define CMD_READ                3'b101
`define CMD_WRITE               3'b100
`define CMD_BURST_TERMINATE     3'b110
`define CMD_PRECHARGE           3'b010
`define CMD_AUTO_REFRESH		3'b001
`define CMD_LOAD_MODE_REGISTER  3'b000
`define CMD_EXT_MODE_REGISTER	3'b000

// CAS Latency
`define Latency_2          		3'b010
`define Latency_3          		3'b011
`define Latency_25         		3'b110

`define Burst_type    1'b0
//		Sequential        = 1'b0;
//		Interleaved       = 1'b1;

`define Burst_Length      3'b001

// Length_2          = 3'b001;
// Length_4          = 3'b010;
// Length_8          = 3'b011;

//`define USE_DRAM
`define USE_REG

//`define  SIMULATION

