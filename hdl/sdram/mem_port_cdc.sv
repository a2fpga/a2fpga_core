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
// Request path (54 MHz → 108 MHz): registered in 108 MHz domain. All request
// signals are captured on the same 108 MHz edge, guaranteeing consistency
// regardless of individual routing delays or CLKDIV2 phase. A 54 MHz wr/rd
// pulse spans 2 cycles at 108 MHz; the register delays it by 1 cycle (still
// 2 cycles wide), and the SDRAM controller's edge detection triggers once.
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
    // Request path: 54 MHz → 108 MHz (registered)
    // =========================================================================
    // All request signals are registered in the 108 MHz domain to guarantee
    // they are captured on the same clock edge. This eliminates sensitivity
    // to routing delay differences between addr/data and wr/rd signals, and
    // to CLKDIV2 initial phase randomness.
    //
    // With CLKDIV2 alignment, 54 MHz signals are stable for 2 full 108 MHz
    // cycles. The register captures them within that window (tolerating up
    // to ~18.5 ns of routing delay). The registered wr/rd pulse is still
    // 2 cycles wide, so the SDRAM controller's edge detection triggers once.

    reg [PORT_ADDR_WIDTH-1:0] req_addr_r;
    reg [DATA_WIDTH-1:0]      req_data_r;
    reg [DQM_WIDTH-1:0]       req_byte_en_r;
    reg                       req_wr_r;
    reg                       req_rd_r;
    reg                       req_burst_r;

    always @(posedge clk_sdram or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_r    <= '0;
            req_data_r    <= '0;
            req_byte_en_r <= '0;
            req_wr_r      <= 1'b0;
            req_rd_r      <= 1'b0;
            req_burst_r   <= 1'b0;
        end else begin
            req_addr_r    <= client.addr;
            req_data_r    <= client.data;
            req_byte_en_r <= client.byte_en;
            req_wr_r      <= client.wr;
            req_rd_r      <= client.rd;
            req_burst_r   <= client.burst;
        end
    end

    assign sdram.addr    = req_addr_r;
    assign sdram.data    = req_data_r;
    assign sdram.byte_en = req_byte_en_r;
    assign sdram.wr      = req_wr_r;
    assign sdram.rd      = req_rd_r;
    assign sdram.burst   = req_burst_r;

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
