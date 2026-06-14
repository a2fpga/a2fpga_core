// Copyright (c) 2023 Adam Gastineau
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

function integer rtoi(input integer x);
    return x;
endfunction

`define CEIL(x) ((rtoi(x) > x) ? rtoi(x) : rtoi(x) + 1)

module sdram #(
    parameter CLOCK_SPEED_MHZ = 0,

    parameter BURST_LENGTH = 1,  // 1, 2, 4, 8 words per read
    parameter BURST_TYPE   = 0,  // 1 for interleaved
    parameter WRITE_BURST  = 0,  // 1 to enable write bursting
    parameter READ_BURST_LENGTH = 4,  // Bytes returned when port burst bit is set

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
    input wire [PORT_ADDR_WIDTH-1:0] port_addr[NUM_PORTS-1:0],
    input wire [DATA_WIDTH-1:0] port_data[NUM_PORTS-1:0],
    input wire [DQM_WIDTH-1:0] port_byte_en[NUM_PORTS-1:0],  // Byte enable for writes
    output reg [PORT_OUTPUT_WIDTH-1:0] port_q[NUM_PORTS-1:0],

    input wire port_wr[NUM_PORTS-1:0],
    input wire port_rd[NUM_PORTS-1:0],
    input wire port_burst[NUM_PORTS-1:0],

    output wire port_available[NUM_PORTS-1:0],  // The port is able to be used
    output reg  port_ready     [NUM_PORTS-1:0],  // The port has finished its task. Will rise for a single cycle

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
    ////////////////////////////////////////////////////////////////////////////////////////
    // Generated parameters

    localparam CLOCK_PERIOD_NANO_SEC = 1000.0 / CLOCK_SPEED_MHZ;

    // Number of cycles after reset until we start command inhibit
    localparam CYCLES_UNTIL_START_INHIBIT =
    `CEIL(SETTING_INHIBIT_DELAY_MICRO_SEC * 500 / CLOCK_PERIOD_NANO_SEC);
    // Number of cycles after reset until we clear command inhibit and start operation
    // We add 100 cycles for good measure
    localparam CYCLES_UNTIL_CLEAR_INHIBIT = 100 +
    `CEIL(SETTING_INHIBIT_DELAY_MICRO_SEC * 1000 / CLOCK_PERIOD_NANO_SEC);

    // Number of cycles for precharge duration
    // localparam CYCLES_FOR_PRECHARGE =
    // `CEIL(SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

    // Number of cycles for autorefresh duration
    localparam CYCLES_FOR_AUTOREFRESH =
    `CEIL(SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

    // Number of cycles between two active commands to the same bank
    // TODO: Use this value
    localparam CYCLES_BETWEEN_ACTIVE_COMMAND =
    `CEIL(SETTING_T_RC_MIN_ACTIVE_TO_ACTIVE_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

    // Number of cycles after active command before a read/write can be executed
    localparam CYCLES_FOR_ACTIVE_ROW =
    `CEIL(SETTING_T_RCD_MIN_READ_WRITE_DELAY_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

    // Number of cycles after write before next command
    localparam CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND =
    `CEIL(
        (SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC + SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC) / CLOCK_PERIOD_NANO_SEC);

    // Number of cycles between each autorefresh command
    localparam CYCLES_PER_REFRESH = `CEIL(SETTING_REFRESH_TIMER_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

    ////////////////////////////////////////////////////////////////////////////////////////
    // Init helpers
    // Number of cycles after reset until we are done with precharge
    // We add 10 cycles for good measure
    localparam CYCLES_UNTIL_INIT_PRECHARGE_END = 10 + CYCLES_UNTIL_CLEAR_INHIBIT +
    `CEIL(SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

    localparam CYCLES_UNTIL_REFRESH1_END = CYCLES_UNTIL_INIT_PRECHARGE_END + CYCLES_FOR_AUTOREFRESH;
    localparam CYCLES_UNTIL_REFRESH2_END = CYCLES_UNTIL_REFRESH1_END + CYCLES_FOR_AUTOREFRESH;

    wire [2:0] concrete_burst_length = BURST_LENGTH == 1 ? 3'h0 : BURST_LENGTH == 2 ? 3'h1 : BURST_LENGTH == 4 ? 3'h2 : 3'h3;
    // Reserved, write burst, operating mode, CAS latency, burst type, burst length
    wire [12:0] configured_mode = {
        3'b0, ~WRITE_BURST[0], 2'b0, CAS_LATENCY[2:0], BURST_TYPE[0], concrete_burst_length
    };
    localparam integer WORD_BYTES = DATA_WIDTH / 8;
    localparam integer READ_BURST_WORDS_UNCLAMPED =
        (READ_BURST_LENGTH + WORD_BYTES - 1) / WORD_BYTES;
    localparam integer READ_BURST_WORDS =
        (READ_BURST_WORDS_UNCLAMPED < 1) ? 1 :
        ((READ_BURST_WORDS_UNCLAMPED > BURST_LENGTH) ? BURST_LENGTH : READ_BURST_WORDS_UNCLAMPED);

    typedef struct packed {
        reg [COL_WIDTH-1:0]  port_addr;
        reg [DATA_WIDTH-1:0] port_data;
        reg [DQM_WIDTH-1:0]  port_byte_en;
    } port_selection;

    // nCS, nRAS, nCAS, nWE
    typedef enum bit [3:0] {
        COMMAND_NOP           = 4'b0111,
        COMMAND_BURST_TERMINATE = 4'b0110,
        COMMAND_ACTIVE        = 4'b0011,
        COMMAND_READ          = 4'b0101,
        COMMAND_WRITE         = 4'b0100,
        COMMAND_PRECHARGE     = 4'b0010,
        COMMAND_AUTO_REFRESH  = 4'b0001,
        COMMAND_LOAD_MODE_REG = 4'b0000
    } command;

    ////////////////////////////////////////////////////////////////////////////////////////
    // State machine

    typedef enum bit [2:0] {
        INIT,
        IDLE,
        DELAY,
        WRITE,
        READ,
        READ_OUTPUT
    } state_fsm;

    state_fsm state;

    // TODO: Could use fewer bits
    reg [31:0] delay_counter = 0;
    // The number of words we're reading
    reg [3:0] read_counter = 0;

    // Measures when auto refresh needs to be triggered
    reg [15:0] refresh_counter = 0;

    state_fsm delay_state;

    typedef enum bit [1:0] {
        IO_NONE,
        IO_WRITE,
        IO_READ
    } io_operation;

    io_operation current_io_operation;

    command sdram_command;
    assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = sdram_command;

    ////////////////////////////////////////////////////////////////////////////////////////
    // Port specifics

    localparam PORT_BITS = NUM_PORTS > 1 ? $clog2(NUM_PORTS) - 1 : 0;
    reg [PORT_BITS:0] active_port = 0;

    reg port_wr_prev[NUM_PORTS-1:0];
    reg port_rd_prev[NUM_PORTS-1:0];
    wire port_wr_req[NUM_PORTS-1:0];
    wire port_rd_req[NUM_PORTS-1:0];

    // Cache the signals we received, potentially while busy
    reg port_wr_queue[NUM_PORTS-1:0];
    reg port_rd_queue[NUM_PORTS-1:0];
    reg port_burst_queue[NUM_PORTS-1:0];
    reg [DQM_WIDTH-1:0] port_byte_en_queue[NUM_PORTS-1:0];
    reg [PORT_ADDR_WIDTH-1:0] port_addr_queue[NUM_PORTS-1:0];
    reg [DATA_WIDTH-1:0] port_data_queue[NUM_PORTS-1:0];

    reg [3:0] read_expected_words;

    wire port_queue[NUM_PORTS-1:0];

    generate
        for (genvar i = 0; i < NUM_PORTS; i++) begin : port_loop
            assign port_wr_req[i] = port_wr[i] && !port_wr_prev[i];
            assign port_rd_req[i] = port_rd[i] && !port_rd_prev[i];

            assign port_queue[i] = port_wr_queue[i] || port_rd_queue[i];

            assign port_available[i] = state == IDLE && ~port_queue[i];

        end
    endgenerate

    ////////////////////////////////////////////////////////////////////////////////////////
    // Helpers

    function automatic [PORT_BITS:0] get_priority_port();
        logic [PORT_BITS:0] result = 0;
        for (int i = 0; i < NUM_PORTS; i++) begin
            if (port_queue[i]) begin
                result = i;
                break;
            end
        end
        //$display("Priority port identified as %b", result);
        return result;
    endfunction

    // Activates a row
    task set_active_command(input [PORT_BITS:0] port);
        //$display("Priority port: %d", port);

        sdram_command <= COMMAND_ACTIVE;

        // Upper two bits choose the bank
        SDRAM_BA <= port_addr_queue[port][PORT_ADDR_WIDTH-1:PORT_ADDR_WIDTH-2];

        // Row address
        SDRAM_A <= port_addr_queue[port][PORT_ADDR_WIDTH-3:COL_WIDTH];

        active_port <= port;
        // Current construction takes two cycles to write next data
        delay_counter <= CYCLES_FOR_ACTIVE_ROW > 32'h2 ? CYCLES_FOR_ACTIVE_ROW - 32'h2 : 32'h0;

        port_wr_queue[port] <= 0;
    endtask

    function port_selection get_active_port();
        port_selection selection;

        selection.port_addr = port_addr_queue[active_port][COL_WIDTH-1:0];
        selection.port_data = port_data_queue[active_port];
        selection.port_byte_en = port_byte_en_queue[active_port];

        return selection;
    endfunction

    reg dq_output = 0;

    reg [DATA_WIDTH-1:0] sdram_data = 0;
    assign SDRAM_DQ = dq_output ? sdram_data : 'Z;

    assign init_complete = state != INIT;

    ////////////////////////////////////////////////////////////////////////////////////////
    // Process

    always @(posedge clk) begin
        if (reset) begin
            // 2. Assert and hold CKE at logic low
            SDRAM_CKE <= 0;

            delay_counter <= 0;

            state <= INIT;
            delay_state <= IDLE;
            current_io_operation <= IO_NONE;

            sdram_command <= COMMAND_NOP;

            for (int i = 0; i < NUM_PORTS; i++) begin
                port_wr_prev[i] <= 0;
                port_rd_prev[i] <= 0;

                port_byte_en_queue[i] <= 0;
                port_addr_queue[i] <= 0;
                port_data_queue[i] <= 0;

                port_wr_queue[i] <= 0;
                port_rd_queue[i] <= 0;
                port_burst_queue[i] <= 0;

                port_ready[i] <= 0;

                port_q[i] <= 0;
            end

            dq_output <= 0;

        end else begin


            for (int i = 0; i < NUM_PORTS; i++) begin
                port_wr_prev[i] <= port_wr[i];
                port_rd_prev[i] <= port_rd[i];
                // Cache port 0 input values
                if (port_wr_req[i]  /*&& current_io_operation != IO_WRITE*/) begin
                    port_wr_queue[i] <= 1;

                    port_byte_en_queue[i] <= port_byte_en[i];
                    port_addr_queue[i] <= port_addr[i];
                    port_data_queue[i] <= port_data[i];
                end else if (port_rd_req[i]  /*&& current_io_operation != IO_READ*/) begin
                    port_rd_queue[i]   <= 1;
                    port_burst_queue[i] <= port_burst[i];

                    port_addr_queue[i] <= port_addr[i];
                end
            end

            // ready pulses for one cycle whenever a transaction beat completes.
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_ready[i] <= 0;
            end

            // Default to NOP at all times in between commands
            // NOP
            sdram_command <= COMMAND_NOP;

            if (state != INIT) begin
                refresh_counter <= refresh_counter + 16'h1;
            end

            case (state)
                INIT: begin
                    delay_counter <= delay_counter + 32'h1;

                    if (delay_counter == CYCLES_UNTIL_START_INHIBIT) begin
                        // Start setting inhibit
                        // 5. Starting at some point during this 100us period, bring CKE high
                        SDRAM_CKE <= 1;

                        // We're already asserting NOP above
                    end else if (delay_counter == CYCLES_UNTIL_CLEAR_INHIBIT) begin
                        // Clear inhibit, start precharge
                        sdram_command <= COMMAND_PRECHARGE;

                        // Mark all banks for refresh
                        SDRAM_A[PRECHARGE_BIT] <= 1;
                    end else if (delay_counter == CYCLES_UNTIL_INIT_PRECHARGE_END || delay_counter == CYCLES_UNTIL_REFRESH1_END) begin
                        // Precharge done (or first auto refresh), auto refresh
                        // CKE high specifies auto refresh
                        SDRAM_CKE <= 1;

                        sdram_command <= COMMAND_AUTO_REFRESH;
                    end else if (delay_counter == CYCLES_UNTIL_REFRESH2_END) begin
                        // Second auto refresh done, load mode register
                        sdram_command <= COMMAND_LOAD_MODE_REG;

                        SDRAM_BA <= '0;

                        SDRAM_A <= configured_mode;
                    end else if (delay_counter == CYCLES_UNTIL_REFRESH2_END + SETTING_T_MRD_MIN_LOAD_MODE_CLOCK_CYCLES) begin
                        // We can now execute commands
                        state <= IDLE;
                    end
                end
                IDLE: begin
                    // Stop outputting on DQ and hold in high Z
                    dq_output <= 0;

                    current_io_operation <= IO_NONE;

                    if (refresh_counter >= CYCLES_PER_REFRESH[15:0]) begin
                        // Trigger refresh
                        state <= DELAY;
                        delay_state <= IDLE;
                        delay_counter <= CYCLES_FOR_AUTOREFRESH - 32'h2;

                        refresh_counter <= 0;

                        sdram_command <= COMMAND_AUTO_REFRESH;
                    end else begin
                        automatic logic [PORT_BITS:0] priority_port = get_priority_port();

                        if (port_wr_queue[priority_port]) begin
                            state <= DELAY;
                            delay_state <= WRITE;

                            current_io_operation <= IO_WRITE;

                            set_active_command(priority_port);
                        end else if (port_rd_queue[priority_port]) begin
                            state <= DELAY;
                            delay_state <= READ;

                            current_io_operation <= IO_READ;

                            set_active_command(priority_port);
                        end
                    end
                end
                DELAY: begin
                    if (delay_counter > 0) begin
                        delay_counter <= delay_counter - 32'h1;
                    end else begin
                        state <= delay_state;
                        delay_state <= IDLE;

                        if (delay_state == IDLE && current_io_operation != IO_NONE) begin
                            port_ready[active_port] <= 1;
                        end
                    end
                end
                WRITE: begin
                    // Write to the selected row
                    port_selection active_port_entries;

                    state <= DELAY;
                    // A write must wait for auto precharge (tWR) and precharge command period (tRP)
                    // Takes one cycle to get back to IDLE, and another to read command
                    delay_counter <= CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND;

                    active_port_entries = get_active_port();

                    sdram_command <= COMMAND_WRITE;

                    // NOTE: Bank is still set from ACTIVE command assertion
                    // High bit enables auto precharge. I assume the top 2 bits are unused
                    SDRAM_A <= '0;
                    SDRAM_A[PRECHARGE_BIT] <= 1'b1;
                    SDRAM_A[COL_WIDTH-1:0] <= active_port_entries.port_addr;
                    // Enable DQ output
                    dq_output <= 1;
                    sdram_data <= active_port_entries.port_data;

                    // Use byte enable from port
                    SDRAM_DQM <= ~active_port_entries.port_byte_en;
                end
                READ: begin
                    // Read to the selected row
                    port_selection active_port_entries;
                    logic [3:0] expected_words_w;

                    expected_words_w = port_burst_queue[active_port] ? 4'(READ_BURST_WORDS) : 4'd1;
                    read_expected_words <= expected_words_w;
                    read_counter <= 0;

                    if (CAS_LATENCY == 1 && ~SETTING_USE_FAST_INPUT_REGISTER) begin
                        // Go directly to read
                        state <= READ_OUTPUT;
                    end else begin
                        state <= DELAY;
                        delay_state <= READ_OUTPUT;

                        // Takes one cycle to go to read data, and one to actually read the data
                        // Fast input register delays operation by a cycle
                        delay_counter <= CAS_LATENCY - 32'h2 + SETTING_USE_FAST_INPUT_REGISTER;
                    end

                    active_port_entries = get_active_port();

                    // Clear queued action
                    port_rd_queue[active_port] <= 0;
                    port_burst_queue[active_port] <= 0;

                    sdram_command <= COMMAND_READ;

                    // NOTE: Bank is still set from ACTIVE command assertion
                    // High bit enables auto precharge. I assume the top 2 bits are unused
                    SDRAM_A <= '0;
                    SDRAM_A[PRECHARGE_BIT] <= 1'b1;
                    SDRAM_A[COL_WIDTH-1:0] <= active_port_entries.port_addr;

                    // Fetch all bytes
                    SDRAM_DQM <= 0;
                end
                READ_OUTPUT: begin
                    // Read data beat is available.
                    port_q[active_port] <= SDRAM_DQ;
                    port_ready[active_port] <= 1;
                    read_counter <= read_counter + 4'd1;

                    // End burst once requested beat count has been returned.
                    if (read_counter + 4'd1 >= read_expected_words) begin
                        state <= IDLE;
                    end

                    // If device burst mode is wider than this request, terminate now.
                    if ((BURST_LENGTH > 1) &&
                        (read_counter + 4'd1 == read_expected_words) &&
                        (read_expected_words < BURST_LENGTH)) begin
                        sdram_command <= COMMAND_BURST_TERMINATE;
                    end

                end
            endcase
        end
    end

    assign SDRAM_CLK = sdram_clk;

    // This DDIO block doesn't double the clock, it just relocates the RAM clock to trigger
    // on the negative edge
    /*
  altddio_out #(
      .extend_oe_disable("OFF"),
      .intended_device_family("Cyclone V"),
      .invert_output("OFF"),
      .lpm_hint("UNUSED"),
      .lpm_type("altddio_out"),
      .oe_reg("UNREGISTERED"),
      .power_up_high("OFF"),
      .width(1)
  ) sdramclk_ddr (
      .datain_h(1'b0),
      .datain_l(1'b1),
      .outclock(clk),
      .dataout(SDRAM_CLK),
      .oe(1'b1),
      .outclocken(1'b1)
      // .aclr(),
      // .aset(),
      // .sclr(),
      // .sset()
  );
  */

    ////////////////////////////////////////////////////////////////////////////////////////
    // Parameter validation

    /*
  initial begin
    $info("Instantiated SDRAM with the following settings");
    $info("  Clock speed %f, period %f", CLOCK_SPEED_MHZ, CLOCK_PERIOD_NANO_SEC);

    if (CLOCK_SPEED_MHZ <= 0 || CLOCK_PERIOD_NANO_SEC <= SETTING_T_CK_MIN_CLOCK_CYCLE_TIME_NANO_SEC) begin
      $error("Invalid clock speed. Quitting");
    end

    $info("--------------------");
    $info("Configured values:");
    $info("  CAS Latency %h", CAS_LATENCY);

    if (CAS_LATENCY != 1 && CAS_LATENCY != 2 && CAS_LATENCY != 3) begin
      $error("Unknown CAS latency");
    end

    $info("  Burst length %h", BURST_LENGTH);

    if (BURST_LENGTH != 1 && BURST_LENGTH != 2 && BURST_LENGTH != 4 && BURST_LENGTH != 8) begin
      $error("Unknown burst length");
    end

    $info("  Burst type %s",
          BURST_TYPE == 0 ? "Sequential" : BURST_TYPE == 1 ? "Interleaved" : "Unknown");

    if (BURST_TYPE != 0 && BURST_TYPE != 1) begin
      $error("Unknown burst type");
    end

    $info("  Write burst %s",
          WRITE_BURST == 0 ? "Single word write" : WRITE_BURST == 1 ? "Write burst" : "Unknown");

    if (WRITE_BURST != 0 && WRITE_BURST != 1) begin
      $error("Unknown write burst");
    end

    $info("--------------------");
    $info("Port values:");
    $info("  Port 0 burst length %d, port width %d", PORT_BURST_LENGTH, PORT_OUTPUT_WIDTH);

    if (PORT_BURST_LENGTH > BURST_LENGTH) begin
      $error("Port 0 burst length exceeds global burst length");
    end

    $info("--------------------");
    $info("Delays:");
    $info("  Cycles until start inhibit %f, clear inhibit %f", CYCLES_UNTIL_START_INHIBIT,
          CYCLES_UNTIL_CLEAR_INHIBIT);

    $info("  Cycles between autorefresh instances %f", CYCLES_PER_REFRESH);

    $info("  CYCLES_FOR_AUTOREFRESH %f", CYCLES_FOR_AUTOREFRESH);
    $info("  CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND %f", CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND);

    $info("  Cycles until between active commands %f, command duration %f",
          CYCLES_BETWEEN_ACTIVE_COMMAND, CYCLES_FOR_ACTIVE_ROW);
  end
*/
endmodule
