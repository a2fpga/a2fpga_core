//
// SystemVerilog port interfaces for the SDRAM module
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// Wraps the SDRAM module with a SystemVerilog port interface for easier
// integration
//

module sdram_ports #(
    parameter CLOCK_SPEED_MHZ = 0,

    parameter BURST_LENGTH = 1,  // 1, 2, 4, 8 words per read
    parameter BURST_TYPE   = 0,  // 1 for interleaved
    parameter WRITE_BURST  = 0,  // 1 to enable write bursting

    parameter CAS_LATENCY = 2,  // 1, 2, or 3 cycle delays

    parameter DATA_WIDTH = 16,
    parameter ROW_WIDTH = 13,  // 2K rows
    parameter COL_WIDTH = 10,  // 256 words per row (1Kbytes)
    parameter PRECHARGE_BIT = 10,  // Default to A10 for precharge
    parameter BANK_WIDTH = 2,  // 4 banks
    parameter DQM_WIDTH = 2,  // 2 bytes

    // SDRAM Config values
    parameter SETTING_INHIBIT_DELAY_MICRO_SEC = 100,

    // tCK - Min clock cycle time
    parameter SETTING_T_CK_MIN_CLOCK_CYCLE_TIME_NANO_SEC = 6,

    // tRAS - Min row active time
    parameter SETTING_T_RAS_MIN_ROW_ACTIVE_TIME_NANO_SEC = 48,

    // tRC - Min row cycle time
    parameter SETTING_T_RC_MIN_ROW_CYCLE_TIME_NANO_SEC = 60,

    // tRP - Min precharge command period
    parameter SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC = 18,

    // tRFC - Min autorefresh period
    parameter SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC = 80,

    // tRC - Min active to active command period for the same bank
    parameter SETTING_T_RC_MIN_ACTIVE_TO_ACTIVE_PERIOD_NANO_SEC = 60,

    // tRCD - Min read/write delay
    parameter SETTING_T_RCD_MIN_READ_WRITE_DELAY_NANO_SEC = 18,

    // tWR - Min write auto precharge recovery time
    parameter SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC = 15,

    // tMRD - Min number of clock cycles between mode set and normal usage
    parameter SETTING_T_MRD_MIN_LOAD_MODE_CLOCK_CYCLES = 2,

    // 8,192 refresh commands every 64ms = 7.8125us, which we round to 7500ns to make sure we hit them all
    parameter SETTING_REFRESH_TIMER_NANO_SEC = 7500,

    // Reads will be delayed by 1 cycle when enabled
    // Highly recommended that you use with SDRAM with FAST_INPUT_REGISTER enabled for timing and stability
    // This makes read timing incompatible with the test model
    parameter SETTING_USE_FAST_INPUT_REGISTER = 1,

    // Port config
    parameter NUM_PORTS = 2,

    parameter PORT_ADDR_WIDTH = 25,
    parameter PORT_BURST_LENGTH = BURST_LENGTH,  // 1, 2, 4, 8 words per read
    parameter PORT_OUTPUT_WIDTH = PORT_BURST_LENGTH * DATA_WIDTH
) (
    input wire clk,
    input wire sdram_clk,
    input wire reset,  // Used to trigger start of FSM
    output wire init_complete,  // SDRAM is done initializing

    // Ports
    sdram_port_if.controller ports[NUM_PORTS-1:0],

    inout  wire [DATA_WIDTH-1:0] SDRAM_DQ,    // Bidirectional data bus
    output reg  [ ROW_WIDTH-1:0] SDRAM_A,     // Address bus
    output reg  [ DQM_WIDTH-1:0] SDRAM_DQM,   // High/low byte mask
    output reg  [BANK_WIDTH-1:0] SDRAM_BA,    // Bank select (single bits)
    output wire                  SDRAM_nCS,   // Chip select, neg triggered
    output wire                  SDRAM_nWE,   // Write enable, neg triggered
    output wire                  SDRAM_nRAS,  // Select row address, neg triggered
    output wire                  SDRAM_nCAS,  // Select column address, neg triggered
    output reg                   SDRAM_CKE,   // Clock enable
    output wire                  SDRAM_CLK    // Chip clock
);

    wire [PORT_ADDR_WIDTH-1:0] port_addr[NUM_PORTS-1:0];
    wire [DATA_WIDTH-1:0] port_data[NUM_PORTS-1:0];
    wire [DQM_WIDTH-1:0] port_byte_en[NUM_PORTS-1:0];
    wire [PORT_OUTPUT_WIDTH-1:0] port_q[NUM_PORTS-1:0];
    wire port_wr[NUM_PORTS-1:0];
    wire port_rd[NUM_PORTS-1:0];
    wire port_available[NUM_PORTS-1:0];
    wire port_ready[NUM_PORTS-1:0];

    generate
        for (genvar i = 0; i < NUM_PORTS; i++) begin : port_interface_loop
            assign port_addr[i] = ports[i].addr;
            assign port_data[i] = ports[i].data;
            assign port_byte_en[i] = ports[i].byte_en;
            assign ports[i].q = port_q[i];
            assign port_wr[i] = ports[i].wr;
            assign port_rd[i] = ports[i].rd;
            assign ports[i].available = port_available[i];
            assign ports[i].ready = port_ready[i];
        end
    endgenerate

    sdram #(
        .CLOCK_SPEED_MHZ(CLOCK_SPEED_MHZ),

        .BURST_LENGTH(BURST_LENGTH),
        .BURST_TYPE  (BURST_TYPE),
        .WRITE_BURST (WRITE_BURST),

        .CAS_LATENCY(CAS_LATENCY),

        .DATA_WIDTH(DATA_WIDTH),
        .ROW_WIDTH(ROW_WIDTH),
        .COL_WIDTH(COL_WIDTH),
        .PRECHARGE_BIT(PRECHARGE_BIT),
        .BANK_WIDTH(BANK_WIDTH),
        .DQM_WIDTH(DQM_WIDTH),

        // SDRAM Config values
        .SETTING_INHIBIT_DELAY_MICRO_SEC(SETTING_INHIBIT_DELAY_MICRO_SEC),

        // tCK - Min clock cycle time
        .SETTING_T_CK_MIN_CLOCK_CYCLE_TIME_NANO_SEC(SETTING_T_CK_MIN_CLOCK_CYCLE_TIME_NANO_SEC),

        // tRAS - Min row active time
        .SETTING_T_RAS_MIN_ROW_ACTIVE_TIME_NANO_SEC(SETTING_T_RAS_MIN_ROW_ACTIVE_TIME_NANO_SEC),

        // tRC - Min row cycle time
        .SETTING_T_RC_MIN_ROW_CYCLE_TIME_NANO_SEC(SETTING_T_RC_MIN_ROW_CYCLE_TIME_NANO_SEC),

        // tRP - Min precharge command period
        .SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC(SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC),

        // tRFC - Min autorefresh period
        .SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC(SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC),

        // tRC - Min active to active command period for the same bank
        .SETTING_T_RC_MIN_ACTIVE_TO_ACTIVE_PERIOD_NANO_SEC(SETTING_T_RC_MIN_ACTIVE_TO_ACTIVE_PERIOD_NANO_SEC),

        // tRCD - Min read/write delay
        .SETTING_T_RCD_MIN_READ_WRITE_DELAY_NANO_SEC(SETTING_T_RCD_MIN_READ_WRITE_DELAY_NANO_SEC),

        // tWR - Min write auto precharge recovery time
        .SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC(SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC),

        // tMRD - Min number of clock cycles between mode set and normal usage
        .SETTING_T_MRD_MIN_LOAD_MODE_CLOCK_CYCLES(SETTING_T_MRD_MIN_LOAD_MODE_CLOCK_CYCLES),

        // 8,192 refresh commands every 64ms = 7.8125us, which we round to 7500ns to make sure we hit them all
        .SETTING_REFRESH_TIMER_NANO_SEC(SETTING_REFRESH_TIMER_NANO_SEC),

        // Reads will be delayed by 1 cycle when enabled
        // Highly recommended that you use with SDRAM with FAST_INPUT_REGISTER enabled for timing and stability
        // This makes read timing incompatible with the test model
        .SETTING_USE_FAST_INPUT_REGISTER(SETTING_USE_FAST_INPUT_REGISTER),

        // Port config
        .NUM_PORTS(NUM_PORTS),

        .PORT_ADDR_WIDTH  (PORT_ADDR_WIDTH),
        .PORT_BURST_LENGTH(PORT_BURST_LENGTH),
        .PORT_OUTPUT_WIDTH(PORT_OUTPUT_WIDTH)
    ) sdram_inst (
        .clk(clk),
        .sdram_clk(sdram_clk),
        .reset(reset),
        .init_complete(init_complete),

        // Ports
        .port_addr(port_addr),
        .port_data(port_data),
        .port_byte_en(port_byte_en),
        .port_q(port_q),
        .port_wr(port_wr),
        .port_rd(port_rd),
        .port_available(port_available),
        .port_ready(port_ready),

        .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_A(SDRAM_A),
        .SDRAM_DQM(SDRAM_DQM),
        .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE),
        .SDRAM_CLK(SDRAM_CLK)
    );


endmodule
