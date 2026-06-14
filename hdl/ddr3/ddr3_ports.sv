//
// Multi-port DDR3 arbiter with CDC
//
// (c) 2026 Ed Anuff <ed@a2fpga.com>
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
// Accepts an array of mem_port_if clients running at clk_client and multiplexes
// them onto a single Gowin DDR3 Memory Interface IP running at clk_ddr.
//
// Architecture:
//   - Per-port asynchronous CDC via ddr3_port_cdc. clk_client (54 MHz) and
//     clk_ddr (81 MHz, = 324 MHz memory clock / 4) come from independent PLLs
//     and are asynchronous.
//   - Static priority arbiter (port 0 = highest) scans for pending requests
//   - Width conversion: 128-bit DDR3 ↔ 32-bit clients
//   - Writes use wr_data_mask to write target bytes within 128-bit word
//   - Burst reads decompose 128-bit response into 4 × 32-bit beats
//   - Non-burst reads extract the addressed 32-bit slot from 128-bit response
//
// DDR3 IP interface follows Gowin DDR3 Memory Interface conventions:
//   - cmd[2:0]: 000=write, 001=read
//   - addr[28:0]: byte address, 16-byte aligned
//   - wr_data[127:0] + wr_data_mask[15:0]: masked write (1=don't write)
//   - rd_data[127:0] + rd_data_valid: read response
//
// Client addressing: PORT_ADDR_WIDTH-bit word address (32-bit words).
//   - addr[1:0] selects 32-bit slot within 128-bit DDR3 burst
//   - addr[PORT_ADDR_WIDTH-1:2] selects 128-bit burst
//   - Per-port base address offset applied via PORT_BASE_ADDR parameter,
//     so clients use local addressing starting from 0.
//

module ddr3_ports #(
    parameter NUM_PORTS = 4,
    parameter PORT_ADDR_WIDTH = 21,
    parameter DATA_WIDTH = 32,
    parameter DQM_WIDTH = 4,
    parameter DDR_ADDR_WIDTH = 29,
    parameter DDR_DATA_WIDTH = 128,
    parameter DDR_MASK_WIDTH = 16,
    // Per-port base address in word-address space (32-bit words).
    // Clients address from 0; the arbiter adds this offset before
    // computing the DDR3 byte address.
    parameter [PORT_ADDR_WIDTH-1:0] PORT_BASE_ADDR [NUM_PORTS] = '{NUM_PORTS{0}},
    // Port index that uses 128-bit wide writes (-1 = none).
    // When active_port matches, S_WRITE uses the full 128-bit data with mask=0.
    parameter integer WIDE_WR_PORT = -1,
    // Port whose burst reads fetch TWO consecutive 128-bit words (8 beats)
    // per granted request instead of one (4 beats). Doubles per-request
    // read throughput for a latency-bound client (framebuffer line fetch)
    // without queueing multiple CDC requests — the CDC sees one ordinary
    // request per round trip. -1 disables.
    parameter integer READ_BURST8_PORT = -1
) (
    input  wire clk_client,          // Client clock (54 MHz, async to clk_ddr)
    input  wire clk_ddr,             // DDR3 controller clock (81 MHz)
    input  wire rst,                 // Active-high reset (clk_ddr domain, from DDR3 IP)
    input  wire init_complete,       // DDR3 calibration complete (clk_ddr domain)

    // Client ports (clk_client domain)
    mem_port_if.controller ports [NUM_PORTS],

    // DDR3 IP command interface (clk_ddr domain)
    input  wire                        cmd_ready,
    output reg  [2:0]                  cmd,
    output reg                         cmd_en,
    output reg  [DDR_ADDR_WIDTH-1:0]   addr,

    // DDR3 IP write interface (clk_ddr domain)
    input  wire                        wr_data_rdy,
    output reg  [DDR_DATA_WIDTH-1:0]   wr_data,
    output reg                         wr_data_en,
    output wire                        wr_data_end,
    output reg  [DDR_MASK_WIDTH-1:0]   wr_data_mask,

    // Wide write data extension (clk_client domain, from framebuffer)
    // Upper 96 bits of 128-bit word; lower 32 bits come via port data.
    // Only used when WIDE_WR_PORT >= 0.  Directly wired to that port's CDC.
    input  wire [95:0]                 wide_wr_data_hi,

    // DDR3 IP read interface (clk_ddr domain)
    input  wire                        rd_data_valid,
    input  wire [DDR_DATA_WIDTH-1:0]   rd_data,
    input  wire                        rd_data_end,

    // Debug (clk_ddr domain) — forces optimizer to preserve CDC FIFO logic
    output wire [NUM_PORTS-1:0]        dbg_req_pending,
    output wire [7:0]                  dbg_arb_state,

    // DDR3 loopback test result (clk_ddr domain)
    // After init_complete, writes 0xA5..A5 to addr 0, reads back, XOR with expected.
    // [31:0] = rd_data[31:0] XOR 0xA5A5A5A5. Zero = DDR3 data path OK.
    output wire [31:0]                 dbg_test_result,
    output wire                        dbg_test_done
);

    assign wr_data_end = 1'b1;  // Single-beat writes (BL8, one 128-bit word)

    localparam CMD_WRITE = 3'b000;
    localparam CMD_READ  = 3'b001;

    localparam PORT_IDX_WIDTH = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1;

    // =========================================================================
    // Per-port CDC instances
    // =========================================================================

    wire [NUM_PORTS-1:0]          cdc_req_pending;
    wire [PORT_ADDR_WIDTH-1:0]    cdc_req_addr    [NUM_PORTS];
    wire [DATA_WIDTH-1:0]         cdc_req_data    [NUM_PORTS];
    wire [DQM_WIDTH-1:0]          cdc_req_byte_en [NUM_PORTS];
    wire [NUM_PORTS-1:0]          cdc_req_wr;
    wire [NUM_PORTS-1:0]          cdc_req_burst;
    wire [95:0]                   cdc_req_wide_hi [NUM_PORTS];
    reg  [NUM_PORTS-1:0]          cdc_req_done;
    reg  [NUM_PORTS-1:0]          cdc_resp_valid;
    reg  [DATA_WIDTH-1:0]         cdc_resp_data;    // Shared bus

    // Per-port mapped addresses: local addr + base offset, REGISTERED in clk_ddr.
    // Together with registered port_ddr_addr, this creates a 2-stage pipeline that
    // breaks the 81 MHz critical path (req_addr → mapped_addr → ddr_addr → FSM).
    // Pipeline stages:
    //   Stage 1: mapped_addr = PORT_BASE_ADDR + cdc_req_addr  (registered)
    //   Stage 2: port_ddr_addr                                (registered)
    // The arbiter's S_LOAD state provides 1 cycle for the pipeline to settle
    // after req_pending goes high. CDC freezes req registers while pending,
    // keeping the pipeline inputs stable.
    reg [PORT_ADDR_WIDTH-1:0] mapped_addr [NUM_PORTS];
    generate
        for (genvar ga = 0; ga < NUM_PORTS; ga++) begin : gen_addr
            always @(posedge clk_ddr or posedge rst) begin
                if (rst)
                    mapped_addr[ga] <= '0;
                else
                    mapped_addr[ga] <= PORT_BASE_ADDR[ga] + cdc_req_addr[ga];
            end
        end
    endgenerate

    // Per-port client status wires (CDC outputs → interface assignments)
    wire [NUM_PORTS-1:0]       cdc_client_available;
    wire [NUM_PORTS-1:0]       cdc_client_ready;
    wire [DATA_WIDTH-1:0]      cdc_client_q [NUM_PORTS];

    generate
        for (genvar gi = 0; gi < NUM_PORTS; gi++) begin : gen_cdc
            // Explicit wire connections break Gowin's interface array
            // flattening bug that reverses port indices in generate loops.
            ddr3_port_cdc #(
                .PORT_ADDR_WIDTH(PORT_ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .DQM_WIDTH(DQM_WIDTH),
                // 16 entries: an 8-beat burst pushed at 81 MHz drains at
                // 54 MHz — 8-deep left no margin against a stalled drain.
                .RESP_FIFO_ADDR_BITS(4)
            ) u_cdc (
                .clk_client       (clk_client),
                .clk_ddr          (clk_ddr),
                .rst              (rst),
                .client_rd        (ports[gi].rd),
                .client_wr        (ports[gi].wr),
                .client_addr      (ports[gi].addr),
                .client_data      (ports[gi].data),
                .client_byte_en   (ports[gi].byte_en),
                .client_burst     (ports[gi].burst),
                .client_wide_data_hi((gi == WIDE_WR_PORT) ? wide_wr_data_hi : 96'd0),
                .client_available (cdc_client_available[gi]),
                .client_ready     (cdc_client_ready[gi]),
                .client_q         (cdc_client_q[gi]),
                .req_pending      (cdc_req_pending[gi]),
                .req_addr         (cdc_req_addr[gi]),
                .req_data         (cdc_req_data[gi]),
                .req_byte_en      (cdc_req_byte_en[gi]),
                .req_wr           (cdc_req_wr[gi]),
                .req_burst        (cdc_req_burst[gi]),
                .req_wide_data_hi (cdc_req_wide_hi[gi]),
                .req_done         (cdc_req_done[gi]),
                .resp_valid       (cdc_resp_valid[gi]),
                .resp_data        (cdc_resp_data),
                .init_complete    (init_complete)
            );

            assign ports[gi].available = cdc_client_available[gi];
            assign ports[gi].ready     = cdc_client_ready[gi];
            assign ports[gi].q         = cdc_client_q[gi];
        end
    endgenerate

    // Debug: expose per-port pending status. This output forces the
    // optimizer to preserve the CDC FIFO empty detection logic — without
    // an observable consumer, Gowin's optimizer collapses the gray-code
    // FIFO through circular constant propagation.
    assign dbg_req_pending = cdc_req_pending;

    // Debug: arbiter state + key signals (clk_ddr domain)
    // [7:4] = state[3:0], [3] = init_complete, [2] = cmd_ready,
    // [1] = rd_data_valid, [0] = test_done
    assign dbg_arb_state = {state, init_complete, cmd_ready,
                            rd_data_valid, test_done};

    // Pre-computed DDR addresses per port (registered, breaks timing path).
    reg [DDR_ADDR_WIDTH-1:0] port_ddr_addr [NUM_PORTS];
    // Second 128-bit word address for READ_BURST8_PORT (mapped_addr + 4
    // 32-bit words = next 128-bit word). Same registered pipeline depth.
    reg [DDR_ADDR_WIDTH-1:0] port_ddr_addr2 [NUM_PORTS];
    generate
        for (genvar gd = 0; gd < NUM_PORTS; gd++) begin : gen_ddr_addr
            always @(posedge clk_ddr or posedge rst) begin
                if (rst) begin
                    port_ddr_addr[gd] <= '0;
                    port_ddr_addr2[gd] <= '0;
                end else begin
                    port_ddr_addr[gd] <= word_to_ddr_addr(mapped_addr[gd]);
                    port_ddr_addr2[gd] <= word_to_ddr_addr(mapped_addr[gd] + 21'd4);
                end
            end
        end
    endgenerate

    // =========================================================================
    // Arbiter state machine (clk_ddr domain)
    // =========================================================================

    localparam S_IDLE      = 4'd0;
    localparam S_LOAD      = 4'd1;   // Pipeline settle: latch addresses
    localparam S_WRITE     = 4'd2;
    localparam S_READ_CMD  = 4'd3;
    localparam S_READ_WAIT = 4'd4;
    localparam S_RESPOND   = 4'd5;
    localparam S_DONE      = 4'd6;
    localparam S_TEST_WR   = 4'd7;   // DDR3 loopback: write test pattern
    localparam S_TEST_RD   = 4'd8;   // DDR3 loopback: issue read
    localparam S_TEST_WAIT = 4'd9;   // DDR3 loopback: check result
    localparam S_READ_CMD2 = 4'd10;  // Second 128-bit read for READ_BURST8_PORT
    reg [3:0] state;
    reg [PORT_IDX_WIDTH-1:0] active_port;
    reg                      active_wr;
    reg                      active_burst;
    reg [1:0]                active_slot;
    reg [DDR_ADDR_WIDTH-1:0] active_ddr_addr;
    reg [DDR_DATA_WIDTH-1:0] rd_data_latched;
    reg [1:0]                beat_cnt;
    // 8-beat read sequencing (READ_BURST8_PORT only)
    reg                      active_burst8;     // This grant fetches 2 words
    reg                      burst8_phase2;     // Second word in progress
    reg [DDR_ADDR_WIDTH-1:0] active_ddr_addr2;  // Second word's DDR address

    // =========================================================================
    // DDR3 loopback test registers
    // =========================================================================
    localparam [DDR_DATA_WIDTH-1:0] TEST_PATTERN = {4{32'hA5A5A5A5}};
    // Byte address for loopback test. Must NOT overlap any port's address range.
    // Double-buffered FB uses word addresses 0..0x4B000 = DDR3 byte 0..0x12C000.
    // SHADOW at word 0x050000, ENSONIQ at word 0x080000.
    // 0x0400000 (4MB) is safely above all used regions.
    localparam [DDR_ADDR_WIDTH-1:0] TEST_ADDR = {DDR_ADDR_WIDTH{1'b0}} | 29'h0400000;

    reg        test_done;
    reg [31:0] test_result;

    assign dbg_test_result = test_result;
    assign dbg_test_done   = test_done;

    // Compute DDR3 address from client word address.
    // Client addr is PORT_ADDR_WIDTH bits of 32-bit word addressing.
    // DDR3 addr is DDR_ADDR_WIDTH bits of byte addressing, 16-byte aligned.
    // addr[1:0] = slot within 128-bit word (not sent to DDR3).
    // addr[PORT_ADDR_WIDTH-1:2] = burst address, shifted left by 4.
    localparam BURST_ADDR_WIDTH = PORT_ADDR_WIDTH - 2;
    localparam PAD_WIDTH = DDR_ADDR_WIDTH - BURST_ADDR_WIDTH - 4;

    function [DDR_ADDR_WIDTH-1:0] word_to_ddr_addr;
        input [PORT_ADDR_WIDTH-1:0] word_addr;
        begin
            word_to_ddr_addr = {{PAD_WIDTH{1'b0}}, word_addr[PORT_ADDR_WIDTH-1:2], 4'b0};
        end
    endfunction

    // Write mask: mask all 16 bytes, then unmask the 4 bytes at the target slot,
    // gated by client byte_en. wr_data_mask is active-high (1 = don't write).
    function [DDR_MASK_WIDTH-1:0] compute_write_mask;
        input [1:0]            slot;
        input [DQM_WIDTH-1:0]  byte_en;
        reg [DDR_MASK_WIDTH-1:0] mask;
        begin
            mask = {DDR_MASK_WIDTH{1'b1}};
            case (slot)
                2'd0: mask[3:0]   = ~byte_en;
                2'd1: mask[7:4]   = ~byte_en;
                2'd2: mask[11:8]  = ~byte_en;
                2'd3: mask[15:12] = ~byte_en;
            endcase
            compute_write_mask = mask;
        end
    endfunction

    // Extract 32-bit slot from 128-bit DDR3 read data
    function [DATA_WIDTH-1:0] extract_slot;
        input [DDR_DATA_WIDTH-1:0] ddr_data;
        input [1:0]                slot;
        begin
            case (slot)
                2'd0: extract_slot = ddr_data[31:0];
                2'd1: extract_slot = ddr_data[63:32];
                2'd2: extract_slot = ddr_data[95:64];
                2'd3: extract_slot = ddr_data[127:96];
            endcase
        end
    endfunction

    always @(posedge clk_ddr or posedge rst) begin
        if (rst) begin
            state          <= S_IDLE;
            cmd_en         <= 1'b0;
            cmd            <= CMD_READ;
            addr           <= '0;
            wr_data_en     <= 1'b0;
            wr_data        <= '0;
            wr_data_mask   <= {DDR_MASK_WIDTH{1'b1}};
            cdc_req_done   <= '0;
            cdc_resp_valid <= '0;
            cdc_resp_data  <= '0;
            active_port    <= '0;
            active_wr      <= 1'b0;
            active_burst   <= 1'b0;
            active_slot    <= 2'b0;
            active_ddr_addr <= '0;
            active_ddr_addr2 <= '0;
            active_burst8  <= 1'b0;
            burst8_phase2  <= 1'b0;
            rd_data_latched <= '0;
            beat_cnt       <= 2'b0;
            test_done      <= 1'b0;
            test_result    <= '0;
        end else begin
            // Default: deassert one-cycle pulses
            cmd_en         <= 1'b0;
            wr_data_en     <= 1'b0;
            cdc_req_done   <= '0;
            cdc_resp_valid <= '0;

            case (state)
                S_IDLE: begin
                    if (init_complete && !test_done) begin
                        // Run loopback test before normal operation
                        state <= S_TEST_WR;
                    end else if (init_complete) begin : pick_port
                        integer i;
                        for (i = 0; i < NUM_PORTS; i = i + 1) begin
                            if (cdc_req_pending[i]) begin
                                active_port  <= i[PORT_IDX_WIDTH-1:0];
                                active_wr    <= cdc_req_wr[i];
                                active_burst <= cdc_req_burst[i];
                                state        <= S_LOAD;
                                disable pick_port;
                            end
                        end
                    end
                end

                // S_LOAD: wait 1 cycle for pipeline (mapped_addr → port_ddr_addr)
                // to settle, then latch addresses. Also validates the request is
                // still pending — if req_done cleared it (ghost from previous
                // transaction), return to S_IDLE without servicing.
                S_LOAD: begin
                    if (cdc_req_pending[active_port]) begin
                        active_slot     <= mapped_addr[active_port][1:0];
                        active_ddr_addr <= port_ddr_addr[active_port];
                        active_ddr_addr2 <= port_ddr_addr2[active_port];
                        active_burst8   <= (READ_BURST8_PORT >= 0) &&
                                           (active_port == READ_BURST8_PORT[PORT_IDX_WIDTH-1:0]) &&
                                           active_burst && !active_wr;
                        burst8_phase2   <= 1'b0;
                        state <= active_wr ? S_WRITE : S_READ_CMD;
                    end else begin
                        state <= S_IDLE;  // Ghost squashed
                    end
                end

                S_WRITE: begin
                    if (cmd_ready && wr_data_rdy) begin
                        cmd_en       <= 1'b1;
                        cmd          <= CMD_WRITE;
                        addr         <= active_ddr_addr;
                        wr_data_en   <= 1'b1;
                        if (WIDE_WR_PORT >= 0 &&
                            active_port == WIDE_WR_PORT[PORT_IDX_WIDTH-1:0]) begin
                            // 128-bit wide write: full data, no mask
                            wr_data      <= {cdc_req_wide_hi[active_port],
                                             cdc_req_data[active_port]};
                            wr_data_mask <= {DDR_MASK_WIDTH{1'b0}};
                        end else begin
                            wr_data      <= {4{cdc_req_data[active_port]}};
                            wr_data_mask <= compute_write_mask(active_slot,
                                                              cdc_req_byte_en[active_port]);
                        end
                        state <= S_DONE;
                    end
                end

                S_READ_CMD: begin
                    if (cmd_ready) begin
                        cmd_en <= 1'b1;
                        cmd    <= CMD_READ;
                        addr   <= active_ddr_addr;
                        state  <= S_READ_WAIT;
                    end
                end

                S_READ_WAIT: begin
                    if (rd_data_valid) begin
                        rd_data_latched <= rd_data;
                        beat_cnt        <= active_burst ? 2'd0 : active_slot;
                        state <= S_RESPOND;
                    end
                end

                S_RESPOND: begin
                    cdc_resp_valid[active_port] <= 1'b1;
                    cdc_resp_data <= extract_slot(rd_data_latched, beat_cnt);

                    if (active_burst) begin
                        beat_cnt <= beat_cnt + 2'd1;
                        if (beat_cnt == 2'd3)
                            state <= (active_burst8 && !burst8_phase2) ?
                                     S_READ_CMD2 : S_DONE;
                    end else begin
                        state <= S_DONE;
                    end
                end

                // Second 128-bit read for an 8-beat burst — beats 4-7 flow
                // through the same S_READ_WAIT/S_RESPOND path, then S_DONE.
                S_READ_CMD2: begin
                    if (cmd_ready) begin
                        cmd_en <= 1'b1;
                        cmd    <= CMD_READ;
                        addr   <= active_ddr_addr2;
                        burst8_phase2 <= 1'b1;
                        state  <= S_READ_WAIT;
                    end
                end

                S_DONE: begin
                    cdc_req_done[active_port] <= 1'b1;
                    state <= S_IDLE;
                end

                // =============================================================
                // DDR3 loopback test: write TEST_PATTERN, read back, XOR
                // =============================================================
                S_TEST_WR: begin
                    if (cmd_ready && wr_data_rdy) begin
                        cmd_en       <= 1'b1;
                        cmd          <= CMD_WRITE;
                        addr         <= TEST_ADDR;
                        wr_data_en   <= 1'b1;
                        wr_data      <= TEST_PATTERN;
                        wr_data_mask <= {DDR_MASK_WIDTH{1'b0}};  // Write all bytes
                        state        <= S_TEST_RD;
                    end
                end

                S_TEST_RD: begin
                    if (cmd_ready) begin
                        cmd_en <= 1'b1;
                        cmd    <= CMD_READ;
                        addr   <= TEST_ADDR;
                        state  <= S_TEST_WAIT;
                    end
                end

                // XOR read data with expected pattern — 0x0000 = pass
                S_TEST_WAIT: begin
                    if (rd_data_valid) begin
                        test_result <= rd_data[31:0] ^ TEST_PATTERN[31:0];
                        test_done   <= 1'b1;
                        state       <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
