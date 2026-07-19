//
// CDC wrapper for mem_port_if — bridges 54 MHz clients to 108 MHz SDRAM
//
// (c) 2025 Ed Anuff <ed@a2fpga.com>
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
// Clock domain crossing wrapper between a 54 MHz mem_port_if client and a
// 108 MHz mem_port_if controller (SDRAM). Designed for use with Gowin CLKDIV2
// where 54 MHz is derived from 108 MHz, guaranteeing that every 54 MHz rising
// edge coincides with a 108 MHz rising edge.
//
// Request path (54 MHz → 108 MHz): 4-entry gray-code FIFO, mirroring the
// response path. The whole request tuple {addr, data, byte_en, wr, rd, burst}
// is written atomically in the 54 MHz domain and read in the 108 MHz domain
// only after the gray-coded write pointer has passed through a 2FF
// synchronizer — by which time the FIFO word is long stable. Atomicity
// therefore does not depend on routing delays. (The previous single-edge
// re-registration required every request bit to arrive within the same
// 9.26 ns half-cycle bucket; with set_false_path on the crossing that budget
// was never verified by timing analysis, and a single slow-routed bit could
// tear a request — wrong-word/wrong-address transactions at 32-bit-word
// granularity.) The pop side re-shapes each request into a 1-cycle wr/rd
// assert followed by a 1-cycle gap, so the SDRAM controller's edge detection
// triggers exactly once per request; peak client rate (one request per 54 MHz
// cycle) matches the 2-cycles-per-pop drain rate at 108 MHz.
//
// Available path (108 MHz → 54 MHz): registered in 54 MHz domain. Prevents
// combinational consumers from seeing transient 108 MHz transitions.
//
// Response path (108 MHz → 54 MHz): 8-entry gray-code FIFO. The ready signal
// is a 1-cycle pulse at 108 MHz that would be missed by 54 MHz sampling.
// Burst-2 reads produce 2 consecutive ready pulses requiring buffering.
// Gray-code pointers with 2FF synchronization ensure CDC robustness
// regardless of routing delays — only one bit changes per pointer increment,
// so cross-domain reads never see transient garbage values.
//

module mem_port_cdc #(
    parameter PORT_ADDR_WIDTH = 21,
    parameter DATA_WIDTH = 32,
    parameter DQM_WIDTH = 4,
    parameter PORT_OUTPUT_WIDTH = 32
) (
    input  wire clk_client,    // 54 MHz client clock (from CLKDIV2)
    input  wire clk_sdram,     // 108 MHz SDRAM clock
    input  wire rst_n,

    // Client-facing port (54 MHz consumers connect here)
    mem_port_if.controller client,

    // SDRAM-facing port (connects to sdram_ports)
    mem_port_if.client sdram
);

    // =========================================================================
    // Request path: 54 MHz → 108 MHz (4-entry gray-code FIFO, self-timed)
    // =========================================================================
    // The request tuple is written atomically in the launch (54 MHz) domain
    // and read in the 108 MHz domain only after the gray-coded write pointer
    // clears a 2FF synchronizer, so the FIFO word is guaranteed stable at
    // read time — correctness does not depend on routing delays, matching
    // the response path's design (and the SDC's blanket false_path on this
    // crossing remains sound). See header for the tearing hazard this fixes.
    //
    // Pop side: each request is presented as a 1-cycle wr/rd assert plus a
    // 1-cycle gap, so the controller's rising-edge detect fires once per
    // request (the controller latches {byte_en, addr, data} on that edge).
    // Drain rate (2 clk_sdram cycles/request) equals the peak client rate
    // (1 request per clk_client cycle); depth 4 absorbs the 2FF latency.

    localparam REQ_W      = PORT_ADDR_WIDTH + DATA_WIDTH + DQM_WIDTH + 3;
    localparam RQ_B_BURST = 0;
    localparam RQ_B_RD    = 1;
    localparam RQ_B_WR    = 2;
    localparam RQ_B_BE    = 3;                        // [RQ_B_BE +: DQM_WIDTH]
    localparam RQ_B_DATA  = RQ_B_BE + DQM_WIDTH;      // [RQ_B_DATA +: DATA_WIDTH]
    localparam RQ_B_ADDR  = RQ_B_DATA + DATA_WIDTH;   // [RQ_B_ADDR +: PORT_ADDR_WIDTH]

    localparam RQ_DEPTH = 4;
    localparam RQ_ABITS = 2;
    localparam RQ_PTRW  = RQ_ABITS + 1;               // extra bit for wrap

    reg [REQ_W-1:0]   req_fifo_mem [0:RQ_DEPTH-1];
    reg [RQ_PTRW-1:0] req_wr_ptr;                     // 54 MHz domain
    reg [RQ_PTRW-1:0] req_rd_ptr;                     // 108 MHz domain

    wire [RQ_PTRW-1:0] req_wr_gray = req_wr_ptr ^ (req_wr_ptr >> 1);
    wire [RQ_PTRW-1:0] req_rd_gray = req_rd_ptr ^ (req_rd_ptr >> 1);

    // --- Push side (54 MHz): capture the whole tuple on any request event ---
    always @(posedge clk_client or negedge rst_n) begin
        if (!rst_n) begin
            req_wr_ptr <= '0;
        end else if (client.wr || client.rd) begin
            req_fifo_mem[req_wr_ptr[RQ_ABITS-1:0]] <=
                {client.addr, client.data, client.byte_en,
                 client.wr, client.rd, client.burst};
            req_wr_ptr <= req_wr_ptr + 1'd1;
        end
    end

    // --- 2FF synchronizer: write pointer → 108 MHz (for empty detection) ---
    (* syn_preserve=1 *) reg [RQ_PTRW-1:0] req_wr_gray_sync1, req_wr_gray_sync2;
    always @(posedge clk_sdram or negedge rst_n) begin
        if (!rst_n) begin
            req_wr_gray_sync1 <= '0;
            req_wr_gray_sync2 <= '0;
        end else begin
            req_wr_gray_sync1 <= req_wr_gray;
            req_wr_gray_sync2 <= req_wr_gray_sync1;
        end
    end

    wire req_fifo_empty = (req_wr_gray_sync2 == req_rd_gray);

    // No full check needed: depth 4 vs a 2-entry worst-case in-flight window
    // (drain matches peak push rate; only 2FF latency can accumulate), and —
    // as with the response FIFO — a full flag seeded by metastable reset
    // deassertion in the other domain could wedge the port permanently.

    // --- Pop side (108 MHz): 1-cycle assert + 1-cycle gap per request ---
    reg               req_assert_r;
    reg [REQ_W-1:0]   req_cur_r;

    always @(posedge clk_sdram or negedge rst_n) begin
        if (!rst_n) begin
            req_rd_ptr   <= '0;
            req_assert_r <= 1'b0;
            req_cur_r    <= '0;
        end else if (req_assert_r) begin
            req_assert_r <= 1'b0;             // gap: guarantees a fresh edge per request
        end else if (!req_fifo_empty) begin
            req_cur_r    <= req_fifo_mem[req_rd_ptr[RQ_ABITS-1:0]];
            req_rd_ptr   <= req_rd_ptr + 1'd1;
            req_assert_r <= 1'b1;
        end
    end

    assign sdram.addr    = req_cur_r[RQ_B_ADDR +: PORT_ADDR_WIDTH];
    assign sdram.data    = req_cur_r[RQ_B_DATA +: DATA_WIDTH];
    assign sdram.byte_en = req_cur_r[RQ_B_BE   +: DQM_WIDTH];
    assign sdram.wr      = req_assert_r & req_cur_r[RQ_B_WR];
    assign sdram.rd      = req_assert_r & req_cur_r[RQ_B_RD];
    // burst is held (like addr/data) until the next pop — same lifetime the
    // old registered path provided.
    assign sdram.burst   = req_cur_r[RQ_B_BURST];

    // =========================================================================
    // Available path: 108 MHz → 54 MHz (registered)
    // =========================================================================
    // Registered in the 54 MHz domain to prevent combinational consumers
    // (e.g. sdram_framebuffer's fifo_pop_w = !fifo_empty && available) from
    // seeing transient 108 MHz transitions between 54 MHz clock edges.
    // Without this, a write can reach the SDRAM (via combinational wr
    // pass-through) while the 54 MHz FIFO pointer never advances.

    reg client_available_r;
    always @(posedge clk_client or negedge rst_n) begin
        if (!rst_n)
            client_available_r <= 1'b0;
        else
            client_available_r <= sdram.available;
    end
    assign client.available = client_available_r;

    // =========================================================================
    // Response path: 108 MHz → 54 MHz (8-entry gray-code FIFO)
    // =========================================================================
    // ready is a 1-cycle pulse at 108 MHz — could be missed by 54 MHz.
    // Burst-2 reads produce 2 consecutive ready pulses needing buffering.
    // FIFO stores q on each 108 MHz ready pulse, delivers at 54 MHz.
    //
    // Gray-code pointers with 2FF synchronization:
    //   - Only one pointer bit changes per increment → no transient glitches
    //   - 2FF synchronizer handles metastability on the single changing bit
    //   - Empty/full detection works directly on gray-coded values
    //   - Robust regardless of routing delays (no dependency on path matching)
    //
    // Depth 8: absorbs 2FF synchronization latency (~2 client cycles) plus
    // burst-2 buffering with margin.

    localparam FIFO_DEPTH = 8;
    localparam FIFO_ADDR_BITS = 3;
    localparam PTR_WIDTH = FIFO_ADDR_BITS + 1;  // extra bit for wrap detection

    reg [PORT_OUTPUT_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];

    // --- Binary pointers (used for memory addressing) ---
    reg [PTR_WIDTH-1:0] fifo_wr_ptr;   // 108 MHz domain
    reg [PTR_WIDTH-1:0] fifo_rd_ptr;   // 54 MHz domain

    // --- Gray-code conversions ---
    wire [PTR_WIDTH-1:0] wr_ptr_gray = fifo_wr_ptr ^ (fifo_wr_ptr >> 1);
    wire [PTR_WIDTH-1:0] rd_ptr_gray = fifo_rd_ptr ^ (fifo_rd_ptr >> 1);

    // --- 2FF synchronizer: write pointer → 54 MHz (for empty detection) ---
    (* syn_preserve=1 *) reg [PTR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;
    always @(posedge clk_client or negedge rst_n) begin
        if (!rst_n) begin
            wr_gray_sync1 <= '0;
            wr_gray_sync2 <= '0;
        end else begin
            wr_gray_sync1 <= wr_ptr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

    // --- FIFO status (gray-code comparison) ---
    // Empty: all gray-code bits match (synchronized wr pointer vs local rd pointer)
    wire fifo_empty = (wr_gray_sync2 == rd_ptr_gray);

    // No full check needed: depth 8 with burst-2 max gives ample headroom.
    // The old binary FIFO (depth 4) also had no full check. Removing it avoids
    // a critical bug: the rd_ptr→108MHz 2FF sync uses async rst_n (54 MHz domain),
    // and metastable reset deassertion in the 108 MHz domain could cause
    // rd_gray_sync2 to initialize to a non-zero value (e.g. gray(8)=1100),
    // making fifo_full=true at startup and permanently blocking all writes.

    // --- Write side (108 MHz): push on each ready pulse ---
    always @(posedge clk_sdram or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
        end else if (sdram.ready) begin
            fifo_mem[fifo_wr_ptr[FIFO_ADDR_BITS-1:0]] <= sdram.q;
            fifo_wr_ptr <= fifo_wr_ptr + 1'd1;
        end
    end

    // --- Read side (54 MHz): pop and deliver ---
    reg                          client_ready_r;
    reg [PORT_OUTPUT_WIDTH-1:0]  client_q_r;

    always @(posedge clk_client or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd_ptr    <= '0;
            client_ready_r <= 1'b0;
            client_q_r     <= '0;
        end else if (!fifo_empty) begin
            client_q_r     <= fifo_mem[fifo_rd_ptr[FIFO_ADDR_BITS-1:0]];
            fifo_rd_ptr    <= fifo_rd_ptr + 1'd1;
            client_ready_r <= 1'b1;
        end else begin
            client_ready_r <= 1'b0;
        end
    end

    assign client.q     = client_q_r;
    assign client.ready = client_ready_r;

endmodule
