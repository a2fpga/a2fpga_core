//
// Async CDC wrapper -- bridges 54 MHz client clock to 81 MHz DDR3
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
// Clock domain crossing between a 54 MHz client port and an 81 MHz DDR3
// arbiter. Clocks are fully asynchronous (independent PLLs).
//
// Double-buffered request protocol (2-entry async FIFO):
//   - Client domain writes requests into a 2-slot FIFO using a gray-coded
//     write pointer. The client can have up to 2 requests in flight
//     simultaneously, so "available" only drops when both slots are occupied.
//   - The write pointer is synchronized into clk_ddr via 2FF. When the DDR
//     side sees a non-empty FIFO, it captures the request data into clk_ddr
//     registers and asserts pending_r (with a 1-cycle delay for the
//     ddr3_ports mapped_addr pipeline).
//   - When the arbiter pulses req_done, the DDR side increments the read
//     pointer and immediately checks for the next queued request. This
//     eliminates the cross-clock round-trip latency of the toggle handshake:
//     the next request starts within ~3 DDR cycles instead of ~7+.
//   - The read pointer is synchronized back to clk_client via 2FF for the
//     "full" (available) check.
//
// Why 2-entry FIFO instead of toggle handshake:
//   The toggle handshake required a full cross-clock round-trip between
//   consecutive requests: ack_toggle syncs to client (2 client cycles),
//   client fires, new toggle syncs to DDR (2 DDR cycles), plus edge detect
//   and capture delays. Total ~7+ DDR cycles of dead time. The 2-entry FIFO
//   allows the next request to be queued in the FIFO WHILE the current one
//   is being serviced, so the DDR side can chain back-to-back with only
//   ~3 DDR cycles gap (capture + pipeline delay).
//
// Request data is double-buffered:
//   - FIFO slots: written in clk_client, stable by the time clk_ddr reads
//     (guaranteed by 2FF gray-code pointer sync providing 2+ DDR cycles
//     of data stability).
//   - clk_ddr capture registers: what the arbiter actually reads, ensuring
//     all downstream logic samples same-domain values.
//
// Response path (81 MHz -> 54 MHz): gray-code FIFO with 2FF synchronized
// write pointer. Inherently async-safe. Unchanged from toggle design.
//
// IMPORTANT: All client-facing signals use explicit wire ports (not
// SystemVerilog interfaces). Gowin's optimizer reverses interface array
// indices during flattening in generate loops, causing CDC instances
// to connect to wrong-port signals. Explicit wires avoid this bug.
//

module ddr3_port_cdc #(
    parameter PORT_ADDR_WIDTH = 21,
    parameter DATA_WIDTH = 32,
    parameter DQM_WIDTH = 4,
    parameter RESP_FIFO_ADDR_BITS = 3  // 2^3 = 8 entries
) (
    input  wire clk_client,          // 54 MHz client clock (independent PLL)
    input  wire clk_ddr,             // 81 MHz DDR3 controller clock
    input  wire rst,                 // Active-high reset (async)

    // Client-facing port (clk_client domain) -- explicit wires to avoid
    // Gowin interface array flattening bug
    input  wire                        client_rd,
    input  wire                        client_wr,
    input  wire [PORT_ADDR_WIDTH-1:0]  client_addr,
    input  wire [DATA_WIDTH-1:0]       client_data,
    input  wire [DQM_WIDTH-1:0]        client_byte_en,
    input  wire                        client_burst,
    output wire                        client_available,
    output wire                        client_ready,
    output wire [DATA_WIDTH-1:0]       client_q,

    // Optional wide write data extension (clk_client domain)
    // Upper 96 bits of 128-bit DDR3 word; lower 32 bits come via client_data.
    // Tie to 96'd0 for ports that don't use wide writes (optimized away).
    input  wire [95:0]                 client_wide_data_hi,

    // Arbiter-facing request (clk_ddr domain)
    output wire                        req_pending,  // Request waiting for service
    output wire [PORT_ADDR_WIDTH-1:0]  req_addr,     // Stable while req_pending
    output wire [DATA_WIDTH-1:0]       req_data,     // Stable while req_pending
    output wire [DQM_WIDTH-1:0]        req_byte_en,  // Stable while req_pending
    output wire                        req_wr,       // 1=write, 0=read
    output wire                        req_burst,    // Burst read request
    output wire [95:0]                 req_wide_data_hi, // Upper 96 bits (stable while pending)
    input  wire                        req_done,     // Pulse: full transaction complete

    // Arbiter-facing response (clk_ddr domain)
    input  wire                        resp_valid,   // Pulse: response beat available
    input  wire [DATA_WIDTH-1:0]       resp_data,    // Response data word

    // Status (clk_ddr domain)
    input  wire                        init_complete, // DDR3 calibration done

    // Debug (clk_ddr domain): sticky response-FIFO overflow — a beat arrived
    // while the FIFO was full and was dropped instead of wrapping the ring
    output wire                        dbg_resp_overflow
);

    // Response FIFO parameters
    localparam FIFO_DEPTH = 2 ** RESP_FIFO_ADDR_BITS;
    localparam PTR_WIDTH = RESP_FIFO_ADDR_BITS + 1;  // Extra bit for wrap detection

    // Request FIFO: 2 slots (1 address bit + 1 wrap bit = 2-bit pointer)
    localparam REQ_PTR_WIDTH = 2;

    // =========================================================================
    // Client-domain reset: synchronized deassertion
    // =========================================================================
    // `rst` (ddr_rst from the DDR3 IP) is native to clk_ddr; its assertion is
    // async-safe for the clk_client FFs below, but its REMOVAL is asynchronous
    // to clk_client, which could release pointer/sync FFs into metastability.
    // Re-synchronize the deassertion so every client-domain FF leaves reset
    // cleanly. (Traffic gating via init_complete masked this window before,
    // but only incidentally.)
    (* syn_preserve=1 *) reg [1:0] rst_client_sync_r;
    always @(posedge clk_client or posedge rst) begin
        if (rst)
            rst_client_sync_r <= 2'b11;
        else
            rst_client_sync_r <= {rst_client_sync_r[0], 1'b0};
    end
    wire rst_client = rst_client_sync_r[1];

    // =========================================================================
    // Client-domain status sync: init_complete from clk_ddr
    // =========================================================================
    (* syn_preserve=1 *) reg init_sync1, init_sync2;

    always @(posedge clk_client or posedge rst_client) begin
        if (rst_client) begin
            init_sync1 <= 1'b0;
            init_sync2 <= 1'b0;
        end else begin
            init_sync1 <= init_complete;
            init_sync2 <= init_sync1;
        end
    end

    // =========================================================================
    // Client-domain: 2-entry request FIFO (write side)
    // =========================================================================
    // Client writes request data into FIFO slots. Gray-coded write pointer
    // is synchronized to clk_ddr for non-empty detection. Gray-coded read
    // pointer is synchronized back for full detection.

    // BSRAM-packed request FIFO: all fields concatenated into a single wide
    // array. BSRAM eliminates GW5AT cross-clock FF-array data corruption.
    // Pack order (LSB first): addr, data, byte_en, wr, burst, wide_hi
    localparam REQ_PACK_WIDTH = PORT_ADDR_WIDTH + DATA_WIDTH + DQM_WIDTH + 1 + 1 + 96;

    // 2 slots (only bit 0 of the pointers indexes the array)
    (* syn_ramstyle="block_ram" *) reg [REQ_PACK_WIDTH-1:0] req_fifo_packed [0:1];

    // Write pointer (client domain)
    reg [REQ_PTR_WIDTH-1:0] req_wr_ptr;
    wire [REQ_PTR_WIDTH-1:0] req_wr_ptr_gray = req_wr_ptr ^ (req_wr_ptr >> 1);

    // Read pointer gray code synced from DDR domain
    wire [REQ_PTR_WIDTH-1:0] req_rd_ptr_gray_ddr;  // forward decl
    (* syn_preserve=1 *) reg [REQ_PTR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;

    always @(posedge clk_client or posedge rst_client) begin
        if (rst_client) begin
            rd_gray_sync1 <= '0;
            rd_gray_sync2 <= '0;
        end else begin
            rd_gray_sync1 <= req_rd_ptr_gray_ddr;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    // Full detection for 2-entry FIFO (2-bit gray code): pointers are
    // exactly 2 apart when the write gray equals the read gray with the
    // top TWO bits inverted (Cummings) — with 2-bit pointers that is BOTH
    // bits. Gray sequence 00,01,11,10: full pairs are (wr,rd) = (11,00),
    // (10,01), (00,11), (01,10) — i.e. wr_gray == ~rd_gray.
    //
    // BUG HISTORY: this previously inverted only the MSB, which asserted
    // full at occupancy 3 (one too late) whenever the read pointer was
    // even — the third request OVERWROTE the oldest queued slot and was
    // silently lost. Lost writes = permanently dropped pixels; lost reads
    // = response beats that never arrive (deadlocks a pipelined client).
    wire req_fifo_full = (req_wr_ptr_gray == ~rd_gray_sync2);
    wire client_available_w = init_sync2 && !req_fifo_full;
    wire fire_w = client_available_w && (client_wr || client_rd);

    // Pointer update (async assert, synchronized deassert)
    always @(posedge clk_client or posedge rst_client) begin
        if (rst_client)
            req_wr_ptr <= '0;
        else if (fire_w)
            req_wr_ptr <= req_wr_ptr + 1'd1;
    end

    // Burst requests must be 4-word aligned (the arbiter returns beats 0-3 of
    // the 128-bit word regardless of addr[1:0], and the burst8 port further
    // assumes 8-word alignment). Holds today because line strides are
    // multiples of 8 from base 0 — catch violations in simulation.
    // synthesis translate_off
    always @(posedge clk_client) begin
        if (fire_w && client_burst && client_addr[1:0] != 2'b00)
            $error("ddr3_port_cdc: burst request with unaligned address %h",
                   client_addr);
    end
    // synthesis translate_on

    // BSRAM write (separate block, no async reset — required for BSRAM inference)
    always @(posedge clk_client) begin
        if (fire_w)
            req_fifo_packed[req_wr_ptr[0]] <= {
                client_wide_data_hi,  // [154:59]  96 bits
                client_burst,         // [58]       1 bit
                client_wr,            // [57]       1 bit
                client_byte_en,       // [56:53]    4 bits
                client_data,          // [52:21]   32 bits
                client_addr           // [20:0]    21 bits
            };
    end

    assign client_available = client_available_w;

    // =========================================================================
    // DDR-domain: 2-entry request FIFO (read side)
    // =========================================================================
    // Sync write pointer gray from client domain
    (* syn_preserve=1 *) reg [REQ_PTR_WIDTH-1:0] wr_gray_sync1_ddr, wr_gray_sync2_ddr;

    always @(posedge clk_ddr or posedge rst) begin
        if (rst) begin
            wr_gray_sync1_ddr <= '0;
            wr_gray_sync2_ddr <= '0;
        end else begin
            wr_gray_sync1_ddr <= req_wr_ptr_gray;
            wr_gray_sync2_ddr <= wr_gray_sync1_ddr;
        end
    end

    // Read pointer (DDR domain)
    reg [REQ_PTR_WIDTH-1:0] req_rd_ptr;
    wire [REQ_PTR_WIDTH-1:0] req_rd_ptr_gray = req_rd_ptr ^ (req_rd_ptr >> 1);
    assign req_rd_ptr_gray_ddr = req_rd_ptr_gray;

    // Empty detection
    wire req_fifo_empty_ddr = (wr_gray_sync2_ddr == req_rd_ptr_gray);

    // -------------------------------------------------------------------------
    // DDR-domain capture and pending control (BSRAM-pipelined)
    // -------------------------------------------------------------------------
    // BSRAM read has 1-cycle latency, so the pipeline is:
    //   T  : detect non-empty, issue BSRAM read (req_bsram_issued_r)
    //   T+1: BSRAM data available, capture to clk_ddr registers (captured_d)
    //   T+2: captured_d fires -> pending_r raised, mapped_addr settled
    //   T+3: port_ddr_addr settled, arbiter sees pending -> S_LOAD
    //   T+4: S_LOAD samples port_ddr_addr (correct)

    reg [PORT_ADDR_WIDTH-1:0] req_addr_ddr;
    reg [DATA_WIDTH-1:0]      req_data_ddr;
    reg [DQM_WIDTH-1:0]       req_byte_en_ddr;
    reg                       req_wr_ddr;
    reg                       req_burst_ddr;
    reg [95:0]                req_wide_hi_ddr;

    reg pending_r;
    reg captured_d;           // 1-cycle delay for mapped_addr pipeline
    reg req_bsram_issued_r;   // BSRAM read issued, data available next cycle

    // Registered BSRAM read (separate block for dual-port inference)
    reg [REQ_PACK_WIDTH-1:0] req_fifo_rd_r;
    always @(posedge clk_ddr)
        req_fifo_rd_r <= req_fifo_packed[req_rd_ptr[0]];

    always @(posedge clk_ddr or posedge rst) begin
        if (rst) begin
            req_addr_ddr       <= '0;
            req_data_ddr       <= '0;
            req_byte_en_ddr    <= '0;
            req_wr_ddr         <= 1'b0;
            req_burst_ddr      <= 1'b0;
            req_wide_hi_ddr    <= '0;
            pending_r          <= 1'b0;
            captured_d         <= 1'b0;
            req_bsram_issued_r <= 1'b0;
            req_rd_ptr         <= '0;
        end else begin
            // Default: clear capture flag each cycle
            captured_d <= 1'b0;

            // Delayed pending assert: 1 cycle after capture for mapped_addr
            if (captured_d)
                pending_r <= 1'b1;

            // BSRAM data available: unpack into working registers
            if (req_bsram_issued_r) begin
                req_addr_ddr    <= req_fifo_rd_r[PORT_ADDR_WIDTH-1:0];
                req_data_ddr    <= req_fifo_rd_r[PORT_ADDR_WIDTH+DATA_WIDTH-1 : PORT_ADDR_WIDTH];
                req_byte_en_ddr <= req_fifo_rd_r[PORT_ADDR_WIDTH+DATA_WIDTH+DQM_WIDTH-1 : PORT_ADDR_WIDTH+DATA_WIDTH];
                req_wr_ddr      <= req_fifo_rd_r[PORT_ADDR_WIDTH+DATA_WIDTH+DQM_WIDTH];
                req_burst_ddr   <= req_fifo_rd_r[PORT_ADDR_WIDTH+DATA_WIDTH+DQM_WIDTH+1];
                req_wide_hi_ddr <= req_fifo_rd_r[REQ_PACK_WIDTH-1 : PORT_ADDR_WIDTH+DATA_WIDTH+DQM_WIDTH+2];
                captured_d      <= 1'b1;
                req_bsram_issued_r <= 1'b0;
            end

            // Arbiter completion: clear pending, advance read pointer
            if (req_done && pending_r) begin
                pending_r  <= 1'b0;
                req_rd_ptr <= req_rd_ptr + 1'd1;
            end

            // Issue BSRAM read when idle and FIFO non-empty
            if (!req_fifo_empty_ddr && !pending_r && !captured_d && !req_bsram_issued_r) begin
                req_bsram_issued_r <= 1'b1;
            end
        end
    end

    assign req_pending      = pending_r;
    assign req_addr         = req_addr_ddr;
    assign req_data         = req_data_ddr;
    assign req_byte_en      = req_byte_en_ddr;
    assign req_wr           = req_wr_ddr;
    assign req_burst        = req_burst_ddr;
    assign req_wide_data_hi = req_wide_hi_ddr;

    // =========================================================================
    // Response path: 81 MHz -> 54 MHz (gray-code FIFO)
    // =========================================================================
    // Arbiter pushes resp_data on each resp_valid pulse (clk_ddr).
    // Client pops entries when FIFO is non-empty (clk_client).

    // BSRAM-based response FIFO: GW5AT corrupts data bits in FF-array async
    // FIFOs when read/write clocks are independent (see GW5AT Async FIFO CDC
    // Bug in project memory). BSRAM has physically independent clock ports
    // at the silicon level, eliminating cross-clock data corruption.
    (* syn_ramstyle="block_ram" *) reg [DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];

    // --- Write side (clk_ddr domain) ---
    reg [PTR_WIDTH-1:0] fifo_wr_ptr;
    wire [PTR_WIDTH-1:0] wr_ptr_gray = fifo_wr_ptr ^ (fifo_wr_ptr >> 1);

    // Overflow guard: pushing into a full FIFO would silently wrap the
    // pointer over 16 unread beats. Capacity is guaranteed by client
    // discipline today (framebuffer occupancy guard, apple_memory
    // serialization), but that is an undocumented invariant — enforce it:
    // drop the beat instead of corrupting the ring (a dropped beat is
    // caught by the framebuffer's beat-accounting detectors) and latch a
    // sticky flag for the debugger.
    reg [PTR_WIDTH-1:0] rd_gray_sync1_ddr_resp, rd_gray_sync2_ddr_resp;
    always @(posedge clk_ddr or posedge rst) begin
        if (rst) begin
            rd_gray_sync1_ddr_resp <= '0;
            rd_gray_sync2_ddr_resp <= '0;
        end else begin
            rd_gray_sync1_ddr_resp <= rd_ptr_gray;
            rd_gray_sync2_ddr_resp <= rd_gray_sync1_ddr_resp;
        end
    end
    wire resp_fifo_full_ddr =
        (wr_ptr_gray == {~rd_gray_sync2_ddr_resp[PTR_WIDTH-1:PTR_WIDTH-2],
                          rd_gray_sync2_ddr_resp[PTR_WIDTH-3:0]});
    wire resp_push_w = resp_valid && !resp_fifo_full_ddr;

    (* syn_preserve=1 *) reg resp_overflow_sticky_r;
    assign dbg_resp_overflow = resp_overflow_sticky_r;
    always @(posedge clk_ddr or posedge rst) begin
        if (rst)
            resp_overflow_sticky_r <= 1'b0;
        else if (resp_valid && resp_fifo_full_ddr)
            resp_overflow_sticky_r <= 1'b1;
    end
    // synthesis translate_off
    always @(posedge clk_ddr) begin
        if (resp_valid && resp_fifo_full_ddr)
            $error("ddr3_port_cdc: response FIFO overflow — client discipline violated");
    end
    // synthesis translate_on

    // Pointer with async reset
    always @(posedge clk_ddr or posedge rst) begin
        if (rst)
            fifo_wr_ptr <= '0;
        else if (resp_push_w)
            fifo_wr_ptr <= fifo_wr_ptr + 1'd1;
    end

    // BSRAM write (separate block, no async reset)
    always @(posedge clk_ddr) begin
        if (resp_push_w)
            fifo_mem[fifo_wr_ptr[RESP_FIFO_ADDR_BITS-1:0]] <= resp_data;
    end

    // --- Read side (clk_client domain) ---
    // BSRAM has 1-cycle registered read latency. Pipeline:
    //   Cycle N:   present rd_addr to BSRAM, advance ptr if non-empty
    //   Cycle N+1: BSRAM output valid → deliver to client
    // Back-to-back reads when FIFO has multiple entries (1 word/cycle).
    reg [PTR_WIDTH-1:0] fifo_rd_ptr;
    wire [PTR_WIDTH-1:0] rd_ptr_gray = fifo_rd_ptr ^ (fifo_rd_ptr >> 1);

    // Sync write pointer gray code to client domain
    (* syn_preserve=1 *) reg [PTR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;
    always @(posedge clk_client or posedge rst_client) begin
        if (rst_client) begin
            wr_gray_sync1 <= '0;
            wr_gray_sync2 <= '0;
        end else begin
            wr_gray_sync1 <= wr_ptr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

    wire fifo_empty = (wr_gray_sync2 == rd_ptr_gray);

    // Registered BSRAM read (separate always block for proper dual-port inference)
    reg [DATA_WIDTH-1:0] fifo_rd_data_r;
    always @(posedge clk_client)
        fifo_rd_data_r <= fifo_mem[fifo_rd_ptr[RESP_FIFO_ADDR_BITS-1:0]];

    reg                   rd_issued_r;   // BSRAM read issued last cycle
    reg                   client_ready_r;
    reg [DATA_WIDTH-1:0]  client_q_r;

    always @(posedge clk_client or posedge rst_client) begin
        if (rst_client) begin
            fifo_rd_ptr    <= '0;
            rd_issued_r    <= 1'b0;
            client_ready_r <= 1'b0;
            client_q_r     <= '0;
        end else begin
            // Data valid 1 cycle after BSRAM read was issued
            client_ready_r <= rd_issued_r;
            if (rd_issued_r)
                client_q_r <= fifo_rd_data_r;

            // Issue next BSRAM read if FIFO has data
            if (!fifo_empty) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1'd1;
                rd_issued_r <= 1'b1;
            end else begin
                rd_issued_r <= 1'b0;
            end
        end
    end

    assign client_q     = client_q_r;
    assign client_ready = client_ready_r;

endmodule
