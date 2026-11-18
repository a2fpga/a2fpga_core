// Framebuffer — 1080p DisplayPort output via mem_port_if
//
// Derived from framebuffer_480p.sv (which remains the 480p/HDMI variant).
// The framebuffer still stores SOURCE-resolution lines (560x192 Apple II /
// 640x200 IIgs SHR); this read side scans them out into a 1920x1080
// raster with integer x3 horizontal / x5 vertical scaling and centered
// borders (1680x960 or 1920x1000 active) — per
// boards/a2mega/docs/tang_mega_138k_analysis.md. No dividers anywhere:
// both scale factors are tracked with incremental phase counters (cx/cy
// from the DP core advance strictly monotonically), and the clk-domain
// fetch pacing consumes a CDC'd {approach, active, fb_line} bundle
// computed in the pixel domain instead of re-deriving the line number.
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
// Memory-backed framebuffer for 480p HDMI display. Stores rendered Apple II
// video pixels via mem_port_if and reads them back for display output.
// Works with any memory backend (SDRAM via sdram_ports, DDR3 via ddr3_ports)
// that implements the mem_port_if interface.
//
// Architecture:
//   Write path: accepts fb_we/fb_data from renderers (apple_video_fb, vgc_fb),
//               converts RGB666 to RGB565, packs pixel pairs into 32-bit words,
//               buffers in a 256-entry FIFO, and drains via fb_write_port.
//   Read path:  line fetch FSM prefetches scanlines into a dual-port BRAM line
//               buffer, unpacking 2 pixels per 32-bit word.
//               Yields to writes only when FIFO is near full (safety valve).
//   CDC:        only needed for the line buffer (clk write, clk_pixel read)
//               using true dual-port BRAM with independent clocks.
//
// Pixel packing: 2x RGB565 per 32-bit word halves memory access count.
//
// Display: 720x480 @ 59.94 Hz (VIDEO_ID_CODE=2)
//   Apple II modes: [80 border][560 active][80 border] x [48 border][384=192x2][48 border]
//   IIgs SHR modes: [40 border][640 active][40 border] x [40 border][400=200x2][40 border]
//   Integer vertical scaling; scanline dimming lives in scanline_dim.sv
//   at the composite level (this module exports v_scale_o/v_border_o).
//

module framebuffer_1080p #(
    parameter COLOR_BITS = 18,           // RGB666
    // Test pattern modes:
    //   0 = normal (memory data)
    //   1 = test pattern via line buffer (tests BRAM + display pipeline)
    //   2 = test pattern at output (bypasses BRAM entirely, tests display only)
    //   3 = test pattern at write packer input (tests full memory round-trip)
    //   4 = 1-pixel alternating B/W stripes (mixed-color pair test)
    //   6 = frame-alternating solid color (stale-data/FIFO-drop detection)
    parameter TEST_PATTERN = 0,
    // EXP 22: Binary threshold diagnostic — all non-zero pixels become white,
    // zero pixels become black. Makes ghost artifacts maximally visible.
    parameter THRESHOLD_DIAG = 0,
    // Words per burst read — must match the memory backend's burst length.
    // DDR3 (ddr3_ports): 4 beats per burst (128-bit / 32-bit)
    // SDRAM (sdram_ports): 2 beats per burst (64-bit / 32-bit)
    parameter FB_READ_BURST_WORDS = 4,
    // Line-buffer banks (power of two, >= 2). Each bank holds one source
    // line (1024 x RGB565 = one 18 Kb BSRAM block). The display shows each
    // source line for V_SCALE raster lines while the fetcher stays up to
    // LINE_BANKS-1 lines ahead, so 4 banks give ~3 x 74 us of slack at
    // 1080p against a ~25 us line fetch (RESOURCE_AUDIT B3); 8 was the
    // DDR3-era sizing and stays the default for the a2mega.
    parameter LINE_BANKS = 8
) (
    // Clocks and reset
    input  logic        clk,             // 54 MHz logic clock
    input  logic        clk_pixel,       // 27 MHz pixel clock
    input  logic        rst_n,

    // Framebuffer write interface (from apple_video_fb / vgc_fb, clk domain)
    input  logic        fb_vsync,        // Frame start pulse
    input  logic        fb_we,           // Pixel write enable
    input  logic [COLOR_BITS-1:0] fb_data, // RGB666 pixel data
    input  logic [10:0] fb_width,        // Active width: 560 or 640
    input  logic [9:0]  fb_height,       // Active height: 192 or 200

    // Memory port interfaces (SDRAM via sdram_ports or DDR3 via ddr3_ports)
    mem_port_if.client  fb_write_port,   // For writing pixels to memory
    mem_port_if.client  fb_read_port,    // For reading scanlines from memory

    // Raster scan position (pixel clock domain, from the DP core;
    // names kept for the shared seam with the 480p variant)
    input  logic [11:0] hdmi_cx,
    input  logic [10:0] hdmi_cy,

    // Video output (pixel clock domain)
    output logic [7:0]  r_o,
    output logic [7:0]  g_o,
    output logic [7:0]  b_o,

    // Wide write data (upper 96 bits of 128-bit DDR3 word, clk domain)
    // Lower 32 bits go via fb_write_port.data.  Routed to ddr3_port_cdc sideband.
    output logic [95:0] fb_wr_wide_data_hi_o,

    // Configuration
    input  logic [COLOR_BITS-1:0] border_color,
    // Scan-out geometry, exported for the composite-level scanline_dim
    // stage (the effect itself no longer lives in this module)
    output logic [2:0]  v_scale_o,       // raster lines per source line
    output logic [10:0] v_border_o,      // active-window top raster line
    input  logic        sleep_i,         // Output black when high

    // Debug counters/flags (clk domain)
    output logic [7:0]  dbg_fifo_level_o,      // Current FIFO fill level (clamped)
    output logic [7:0]  dbg_fifo_highwater_o,  // Per-frame FIFO high-water mark
    output logic [7:0]  dbg_fifo_overflow_o,   // Dropped packed writes per frame
    output logic [7:0]  dbg_fetch_start_o,     // Line fetch starts per frame
    output logic [7:0]  dbg_fetch_done_o,      // Line fetch completions per frame
    output logic [7:0]  dbg_read_blocked_o,    // Issue cycles blocked by port unavailable
    output logic [7:0]  dbg_yield_busy_o,      // Issue cycles yielding to near-full write FIFO
    output logic [7:0]  dbg_late_line_o,       // Behind-display late-line detections per frame
    output logic [7:0]  dbg_flags_o,           // Live status flags
    output logic [7:0]  dbg_line_not_ready_o,  // Display line-starts before line fully fetched
    output logic [7:0]  dbg_line_lag_max_o,    // Max display-vs-fetched line lag per frame
    output logic [7:0]  dbg_ready_phase_err_o, // Read ready pulses outside FETCH_RUN
    output logic        fetch_active_o,        // High while line fetch issues bursts
                                               // (pipelined-DOC issue gating hint)
    output logic [7:0]  dbg_vsync_raw_o,       // Raw fb_vsync pulses seen in this frame
    output logic [7:0]  dbg_frame_start_accept_o, // Accepted frame starts in this frame
    output logic [7:0]  dbg_frame_start_reject_o, // Rejected fb_vsync pulses in this frame
    output logic [7:0]  dbg_fifo_pop_o,           // FIFO pops (writes sent to DDR3) per frame
    output logic [7:0]  dbg_fifo_push_o,          // FIFO pushes (128-bit words queued) per frame
    output logic [7:0]  dbg_rd_fifo_max_o,        // Peak rd_fifo fill level per frame (0..8)
    output logic [7:0]  dbg_rd_fifo_drop_o,       // Read beats dropped because rd_fifo was full
    output logic [7:0]  dbg_line_not_ready_total_o, // Cumulative not-ready since reset (sticky)
    output logic [7:0]  dbg_beat_extra_o,          // Sticky: ready beats with none expected (duplicates)
    output logic [7:0]  dbg_beat_timeout_o         // Sticky: 19µs stalls awaiting beats (losses)
);

    // =========================================================================
    // 480p display parameters
    // =========================================================================

    localparam HDMI_WIDTH  = 1920;
    localparam HDMI_H_TOTAL = 2200;  // raster line length incl. blanking (cx wraps here)
    localparam H_TRIGGER_LEAD = 12;  // see the h_trigger block in the output path
    localparam HDMI_HEIGHT = 1080;
    localparam H_SCALE     = 3;    // 560->1680 / 640->1920
    localparam V_SCALE     = 5;    // 192->960  / 200->1000
    localparam integer PREFETCH_LEAD_LINES = 12;  // raster lines of approach window

    // Double-buffer disabled: single buffer eliminates slow frame updates
    // caused by Apple II's slow pixel rate vs 60 Hz HDMI refresh.
    localparam [20:0] BUFFER_OFFSET = 21'h0;

    // =========================================================================
    // Color conversion functions
    // =========================================================================

    // RGB666 (18-bit) to RGB565 (16-bit) for packed storage
    function automatic [15:0] rgb666_to_565(input [17:0] c);
        return {c[17:13], c[11:6], c[5:1]};
    endfunction

    // RGB565 (16-bit) to RGB666 (18-bit) for line buffer
    function automatic [17:0] rgb565_to_666(input [15:0] c);
        return {c[15:11], c[15],   // R: 5->6 bits
                c[10:5],           // G: 6 bits
                c[4:0], c[4]};    // B: 5->6 bits
    endfunction

    // RGB666 to RGB888 for HDMI output
    function automatic [23:0] torgb(input [COLOR_BITS-1:0] c);
        return {c[17:12], c[17:16],   // R
                c[11:6],  c[11:10],   // G
                c[5:0],   c[5:4]};    // B
    endfunction

    // Test pattern: 2-pixel wide bars (different colors per 32-bit word)
    // This creates 4 different words within each 128-bit DDR3 burst,
    // making wr_data_mask failures clearly visible:
    //   - Working mask: 2-pixel bars (W R G B C M Y K repeating)
    //   - Broken mask: 8-pixel bars (last word wins, all same color)
    function automatic [COLOR_BITS-1:0] test_pixel(input [9:0] x);
        case (x[3:1])
            3'd0: test_pixel = 18'h3FFFF;  // white  (pixels 0-1)
            3'd1: test_pixel = 18'h3F000;  // red    (pixels 2-3)
            3'd2: test_pixel = 18'h00FC0;  // green  (pixels 4-5)
            3'd3: test_pixel = 18'h0003F;  // blue   (pixels 6-7)
            3'd4: test_pixel = 18'h00FFF;  // cyan   (pixels 8-9)
            3'd5: test_pixel = 18'h3F03F;  // magenta(pixels 10-11)
            3'd6: test_pixel = 18'h3FFC0;  // yellow (pixels 12-13)
            3'd7: test_pixel = 18'h00000;  // black  (pixels 14-15)
        endcase
    endfunction

    // 1-pixel alternating stripes for mixed-pair testing
    function automatic [COLOR_BITS-1:0] test_pixel_mixed(input [9:0] x);
        test_pixel_mixed = x[0] ? 18'h00000 : 18'h3FFFF;  // even=white, odd=black
    endfunction

    // Frame-alternating solid color for stale-data detection
    function automatic [COLOR_BITS-1:0] test_pixel_frame_alt(input parity);
        test_pixel_frame_alt = parity ? 18'h3FFFF : 18'h00000;  // white/black
    endfunction

    // =========================================================================
    // Input registration — 1-cycle pipeline for fb_data/fb_we/fb_vsync
    // =========================================================================
    // EXP 6: TEST_PATTERN=3 (clean) uses an internal register for pixel data,
    // while normal mode uses the external fb_data input through a combinational
    // mux chain. Register all write-path inputs to test whether a marginal
    // timing issue at the input boundary causes the ghosting artifact.

    reg [COLOR_BITS-1:0] fb_data_r;
    reg fb_we_r;
    reg fb_vsync_r;
    // -------------------------------------------------------------------------
    // Reset deassertion synchronizer (clk domain)
    // -------------------------------------------------------------------------
    // rst_n originates in the DDR3 domain (~ddr_rst): assertion is async-safe,
    // but removal is asynchronous to clk, so FFs could leave reset metastable.
    // Re-synchronize the deassertion; every clk-domain block below resets on
    // rst_n_clk. (init-complete gating masked this window before, but only
    // incidentally.)
    reg [1:0] rstn_clk_sync_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rstn_clk_sync_r <= 2'b00;
        else
            rstn_clk_sync_r <= {rstn_clk_sync_r[0], 1'b1};
    end
    wire rst_n_clk = rstn_clk_sync_r[1];

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            fb_data_r <= '0;
            fb_we_r <= 1'b0;
            fb_vsync_r <= 1'b0;
        end else begin
            fb_data_r <= fb_data;
            fb_we_r <= fb_we;
            fb_vsync_r <= fb_vsync;
        end
    end

    // =========================================================================
    // Write FIFO — buffers 128-bit packed pixel groups for memory
    // =========================================================================
    //
    // Each entry: {21-bit addr, 128-bit data} = 149 bits
    // Addr is 128-bit aligned (bits [1:0] always 00).
    // 4 pixel pairs (8 pixels) are accumulated before each FIFO push,
    // yielding one full DDR3 128-bit write with mask=0 per entry.
    // Depth 64 holds ~4.5k pixels (64 × 8 × 8 = ~3.6 lines at 560px).

    localparam FIFO_DEPTH = 64;
    localparam FIFO_ADDR_BITS = 6;  // log2(64)
    // Yield reads only as a safety valve when write FIFO is nearly full.
    localparam FIFO_YIELD_THRESHOLD = 48;

    // BSRAM, not registers: as a register file this was 149x64 = ~9.5K FF
    // plus a 64:1 read mux (~30% of ALL flops in the design, pointer nets
    // at fanout ~3700 on saturated clock spines — see
    // docs/pnr_structural_analysis.md). Sync read + FWFT staging below;
    // the producer/consumer contract is unchanged except entries become
    // consumer-visible 2 cycles after the push (a don't-care for a
    // rate-smoothing FIFO into DDR3).
    // On GW5A this is 5 inferred x32 SDP primitives = 10 blocks (each x32
    // is split in two by Convert_SDP32_36_to_SDP16_18). Writing it as nine
    // 18-bit arrays does not help: GowinSynthesis merges same-addressed
    // arrays back into one wide memory (measured 2026-11-15, RESOURCE_AUDIT
    // B1a); fewer blocks need the beat-organised restructure (B1b).
    reg [148:0] wr_fifo [0:FIFO_DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [FIFO_ADDR_BITS:0] fifo_wr_ptr_r, fifo_rd_ptr_r;
    // Consumer-side copy of the write pointer, one cycle behind: (a) the
    // sync-read output register needs a cycle to present a just-written
    // head entry, and (b) it guarantees the BSRAM never does a same-cycle
    // same-address read-during-write (undefined on Gowin SDPB).
    reg [FIFO_ADDR_BITS:0] fifo_wr_ptr_d1_r;

    wire [FIFO_ADDR_BITS:0] fifo_count_w = fifo_wr_ptr_r - fifo_rd_ptr_r;
    wire fifo_empty_w = (fifo_wr_ptr_d1_r == fifo_rd_ptr_r);
    wire fifo_full_w  = fifo_count_w[FIFO_ADDR_BITS];  // MSB set when count >= 64
    // Start yielding reads earlier so write FIFO never reaches drop-on-full behavior.
    wire fifo_busy_w  = (fifo_count_w >= FIFO_YIELD_THRESHOLD);
    wire [7:0] fifo_count_clamped_w = fifo_count_w[FIFO_ADDR_BITS] ? 8'hFF : {{(8-FIFO_ADDR_BITS){1'b0}}, fifo_count_w[FIFO_ADDR_BITS-1:0]};

    // =========================================================================
    // Write path — pixel packing + 4-pair accumulator + FIFO (clk domain, 54 MHz)
    // =========================================================================
    //
    // Accepts RGB666 pixels from renderers, converts to RGB565, buffers even
    // pixels, packs pairs into 32-bit words, accumulates 4 consecutive pairs
    // (128 bits = one DDR3 word), and pushes to FIFO for memory.
    // Memory address uses packed width (fb_width/2 words per line).
    //
    // All Apple II/IIgs modes produce lines that are multiples of 8 pixels,
    // so the accumulator always fills completely before a line boundary.

    reg [10:0] wr_x_r;
    reg [9:0]  wr_y_r;
    reg [10:0] wr_width_r;           // latched at vsync
    reg [20:0] wr_line_base_r;       // y * (fb_width/2)
    reg [15:0] wr_pixel_even_r;      // buffered even pixel (RGB565)
    reg        frame_pending_r;      // waiting for first fb_we after accepted frame start
    reg        frame_parity_r;      // toggles each frame for TEST_PATTERN==6
    reg        frame_done_parity_r; // buffer the writer last COMPLETED (read side)

    // 4-pair accumulator: collects 4 × 32-bit pixel pairs before FIFO push
    reg [31:0] wr_accum_r [0:2];     // Slots 0-2; slot 3 comes from current pair
    reg [1:0]  wr_accum_slot_r;      // Which slot is next (0-3)
    reg [20:0] wr_accum_addr_r;      // Base address of slot 0 (128-bit aligned)
    // Reject implausibly short frame-start intervals so a spurious fb_vsync
    // pulse cannot reset write/read tracking mid-frame.
    localparam [19:0] FRAME_MIN_CYCLES = 20'd540000;  // ~10ms at 54MHz
    reg [19:0] frame_gap_r;
    wire frame_start_w = fb_vsync_r && (frame_gap_r >= FRAME_MIN_CYCLES);

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            frame_gap_r <= FRAME_MIN_CYCLES;
        end else begin
            if (frame_gap_r != 20'hFFFFF)
                frame_gap_r <= frame_gap_r + 20'd1;
            if (frame_start_w)
                frame_gap_r <= 20'd0;
        end
    end

    // TEST_PATTERN==3: replace renderer data with 8-pixel test bars at write packer input
    // TEST_PATTERN==4: replace with 1-pixel alternating stripes (mixed-color pairs)
    // 3/4/6 test the full round-trip: RGB666→RGB565 → FIFO → memory → fetch → RGB565→RGB666 → BRAM → display
    wire [COLOR_BITS-1:0] wr_pixel_data_w = (TEST_PATTERN == 6) ? test_pixel_frame_alt(frame_parity_r) :
                                             (TEST_PATTERN == 4) ? test_pixel_mixed(wr_x_r[9:0]) :
                                             (TEST_PATTERN == 3) ? test_pixel(wr_x_r[9:0]) : fb_data_r;

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            wr_x_r <= 11'd0;
            wr_y_r <= 10'd0;
            wr_width_r <= 11'd560;
            wr_line_base_r <= 21'd0;
            fifo_wr_ptr_r <= '0;
            wr_pixel_even_r <= 16'd0;
            frame_pending_r <= 1'b0;
            frame_parity_r <= 1'b0;
            frame_done_parity_r <= 1'b1;
            wr_accum_r[0] <= 32'd0;
            wr_accum_r[1] <= 32'd0;
            wr_accum_r[2] <= 32'd0;
            wr_accum_slot_r <= 2'd0;
            wr_accum_addr_r <= 21'd0;
        end else begin
            if (frame_start_w) begin
                frame_done_parity_r <= frame_parity_r;   // the frame just written is complete
                frame_parity_r <= ~frame_parity_r;
                // Arm reset, but align to the first pixel write pulse so
                // wr_x/wr_y stay phase-locked to the producer's fb_we stream.
                frame_pending_r <= 1'b1;
                wr_width_r <= fb_width;
            end

            if (fb_we_r) begin
                if (frame_pending_r || frame_start_w) begin
                    // First pixel of new frame: consume as x=0 even pixel.
                    wr_x_r <= 11'd1;
                    wr_y_r <= 10'd0;
                    wr_line_base_r <= 21'd0;
                    wr_pixel_even_r <= rgb666_to_565(wr_pixel_data_w);
                    frame_pending_r <= 1'b0;
                    wr_accum_slot_r <= 2'd0;
                end else begin
                    if (wr_x_r[0] == 1'b0) begin
                        // Even pixel — buffer as RGB565
                        wr_pixel_even_r <= rgb666_to_565(wr_pixel_data_w);
                    end else begin
                        // Odd pixel — pack with buffered even into 32-bit pair
                        // and accumulate into 128-bit word (4 pairs = 8 pixels)
                        begin : accum_block
                            reg [31:0] pair;
                            pair = {rgb666_to_565(wr_pixel_data_w), wr_pixel_even_r};

                            case (wr_accum_slot_r)
                                2'd0: begin
                                    wr_accum_r[0] <= pair;
                                    wr_accum_addr_r <= (frame_parity_r ? BUFFER_OFFSET : 21'd0) +
                                                       wr_line_base_r + {11'd0, wr_x_r[10:1]};
                                    wr_accum_slot_r <= 2'd1;
                                end
                                2'd1: begin
                                    wr_accum_r[1] <= pair;
                                    wr_accum_slot_r <= 2'd2;
                                end
                                2'd2: begin
                                    wr_accum_r[2] <= pair;
                                    wr_accum_slot_r <= 2'd3;
                                end
                                2'd3: begin
                                    // 4th pair completes the 128-bit word — push to
                                    // FIFO (the BSRAM write itself is the dedicated
                                    // always block below, gated by fifo_push_w which
                                    // mirrors this exact condition)
                                    if (!fifo_full_w)
                                        fifo_wr_ptr_r <= fifo_wr_ptr_r + 1;
                                    // Always reset slot (even on drop — 4 pairs lost together)
                                    wr_accum_slot_r <= 2'd0;
                                end
                            endcase
                        end
                    end

                    // Advance position
                    if (wr_x_r == wr_width_r - 11'd1) begin
                        wr_x_r <= 11'd0;
                        wr_y_r <= wr_y_r + 10'd1;
                        wr_line_base_r <= wr_line_base_r + {11'd0, wr_width_r[10:1]};
                    end else begin
                        wr_x_r <= wr_x_r + 11'd1;
                    end
                end
            end
        end
    end

    // BSRAM write port — fifo_push_w mirrors the pointer-increment
    // condition in the packer FSM above, bit for bit
    wire fifo_push_w = fb_we_r && !frame_pending_r && !frame_start_w &&
                       wr_x_r[0] && (wr_accum_slot_r == 2'd3) && !fifo_full_w;
    wire [148:0] fifo_wdata_w = {
        wr_accum_addr_r,                                    // [148:128] addr
        rgb666_to_565(wr_pixel_data_w), wr_pixel_even_r,    // [127:96]  slot 3
        wr_accum_r[2],                                      // [95:64]   slot 2
        wr_accum_r[1],                                      // [63:32]   slot 1
        wr_accum_r[0]                                       // [31:0]    slot 0
    };
    always @(posedge clk) begin
        if (fifo_push_w)
            wr_fifo[fifo_wr_ptr_r[FIFO_ADDR_BITS-1:0]] <= fifo_wdata_w;
    end

    // FIFO drain to memory write port (128-bit wide write). Sync-read FWFT:
    // the BSRAM output register always holds mem[fifo_rd_ptr_r] — the read
    // address muxes ahead on a pop so back-to-back drains sustain one word
    // per cycle. fifo_empty_w (from the delayed write pointer) guarantees
    // the head register is valid before a pop is allowed.
    reg [148:0] fifo_head_r;
    always @(posedge clk) begin
        fifo_head_r <= wr_fifo[fifo_pop_w ? fifo_rd_ptr_r[FIFO_ADDR_BITS-1:0] + 6'd1
                                          : fifo_rd_ptr_r[FIFO_ADDR_BITS-1:0]];
    end

    wire [20:0]  fifo_addr_w = fifo_head_r[148:128];
    wire [127:0] fifo_data_w = fifo_head_r[127:0];
    wire fifo_pop_w = !fifo_empty_w && fb_write_port.available;

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            fifo_rd_ptr_r <= '0;
            fifo_wr_ptr_d1_r <= '0;
        end else begin
            fifo_wr_ptr_d1_r <= fifo_wr_ptr_r;
            if (fifo_pop_w)
                fifo_rd_ptr_r <= fifo_rd_ptr_r + 1;
        end
    end

    // Lower 32 bits via port data; upper 96 bits via wide sideband
    assign fb_write_port.addr    = fifo_addr_w;
    assign fb_write_port.data    = fifo_data_w[31:0];
    assign fb_write_port.byte_en = 4'b1111;
    assign fb_write_port.wr      = fifo_pop_w;
    assign fb_write_port.rd      = 1'b0;
    assign fb_write_port.burst   = 1'b0;
    assign fb_wr_wide_data_hi_o  = fifo_data_w[127:32];

    // =========================================================================
    // CDC: HDMI cy → clk domain (toggle handshake)
    // =========================================================================
    // NOT gray-coded: gray code only guarantees single-bit transitions for
    // increments, and the 480p raster wraps 524→0, which flips 4 gray bits
    // in one clk_pixel edge. A clk edge sampling mid-transition would decode
    // an arbitrary line number for one cycle — enough to falsely trigger the
    // catch-up or line-0 fetch paths (rare single-line glitch, once per
    // frame wrap at worst).
    //
    // Instead: at each line start capture hdmi_cy into a holding register,
    // flip a toggle ONE clk_pixel later (so the held value is rock-stable
    // before the toggle moves), and sample the held value in the clk domain
    // on the synchronized toggle edge. The full 10-bit value transfers
    // atomically; the hold register is stable for the rest of the line
    // (~63 us) around each sample point.

    // Pixel-domain vertical tracker: fb_line / V_SCALE phase / active and
    // approach flags, advanced incrementally at each raster-line change
    // (hdmi_cy from dp_video_timing is strictly sequential 0..V_TOTAL-1).
    // The x5 division is thereby free — no divider anywhere.
    reg [10:0] v_border_px_r;   // (declared here; loaded in the output section)
    reg [2:0]  v_phase_px_r;    // 0..V_SCALE-1 raster sub-line
    reg [8:0]  fb_line_px_r;    // source line being displayed
    reg        v_active_px_r;
    reg        v_approach_px_r;
    reg [10:0] cy_prev_px_r;
    reg        cy_changed_px_r;
    reg        cy_toggle_px_r;

    // Stage-0 input registration: at 148.5 MHz the route from the DP
    // core's cx/cy counters into the trackers is otherwise the critical
    // path. All tracker events fire during blanking, so the one-cycle
    // delay is invisible; the horizontal lookahead constant compensates.
    (* syn_keep = 1, syn_preserve = 1 *) reg [11:0] cx0_r;   // syn_keep: see debugoverlay.sv —
    (* syn_keep = 1, syn_preserve = 1 *) reg [10:0] cy0_r;   // prevents cross-module reg merging
    always @(posedge clk_pixel) begin
        cx0_r <= hdmi_cx;
        cy0_r <= hdmi_cy;
    end

    // Pre-registered line-event flags (structural timing, 08-31): the raw
    // compares (cy == v_border / v_border-LEAD, fb_line == height-1) fed the
    // tracker CEs directly and were the persistent clk_pix violation family
    // post-wr_fifo (-1.0/-1.2 across draws; synthesis also merged the
    // mode-equivalent h_border[4]/v_border[4] bits, welding the h and v
    // cones together). All three fire once per line against values stable
    // for the whole line, and hdmi_cy is STRICTLY SEQUENTIAL — so each
    // compare is evaluated against cy+1 during the previous line and
    // consumed as a 1-bit flag at the change. At the frame wrap the next
    // line is 0, and 0 never equals v_border (60/40) or v_border-LEAD
    // (48/28), so the +1 form is exact there too. fb_line_last_r is
    // consumed a full line after fb_line_px_r settles.
    // (10-11, a2p25 GW5A-25: the change detect and the cy==0 compare still
    // fed the tracker's update directly — -0.75 ns at 148.5 MHz on the
    // smaller die. The tracker now acts on the REGISTERED change flag, one
    // cycle after cy0_r moved, so the border/lead flags are evaluated
    // against the CURRENT cy0_r (== form) rather than cy+1: at the cycle
    // the tracker reads them, cy0_r already holds the new line. Timing
    // round 2 cones (g)/(o) below add the registered cy==0 flag and a
    // decision stage on top; both read these flags one cycle after the
    // change, which is exactly what the == form is for. 2026-10-22 merge:
    // round 2 had kept the +1 form with the later consumption, which would
    // have put every vertical event one raster line early.)
    reg at_border_nxt_r, at_lead_nxt_r, fb_line_last_r;
    always @(posedge clk_pixel) begin
        at_border_nxt_r <= (cy0_r == v_border_px_r);
        at_lead_nxt_r   <= (cy0_r == v_border_px_r - 11'(PREFETCH_LEAD_LINES));
        fb_line_last_r  <= (fb_line_px_r == fb_height_px_r[8:0] - 9'd1);
    end

    // TIMING ROUND 2 CONE (g): the tracker used the RAW 11-bit compares
    // (cy0_r != cy_prev_px_r, cy0_r == 0) as its CE/reset cone — the
    // clk_pix path "cy_prev_px_r -> v_approach_px_r/RESET" (-0.205 in a
    // 60K roll). Both compares are registered (cy_changed_px_r already
    // existed; cy_zero_px_r is new) and the tracker acts one cycle later.
    // Exact: all tracker events fire in blanking with hundreds of cycles
    // of slack, and the at_border/at_lead/fb_line_last flags are stable
    // across the line, so they read the same value a cycle on.
    reg cy_zero_px_r;
    // Timing campaign round 2, cone (o): even with registered event flags
    // the tracker's enables combined seven of them plus the phase compare
    // in one cycle, and "v_active_px_r -> v_active_px_r/CE" (a flop
    // clearing itself through that cone) landed at +0.00 ns in a 60K roll.
    // One more stage: the decision (zero / border / lead / step, phase
    // last, line last) is registered at the event cycle and applied the
    // cycle after, so every tracker enable is a one-level function of
    // flops. Exact by the same argument as above: every input is stable
    // for the whole line, the tracker itself is the only writer of the
    // state it reads, and events fire in blanking hundreds of cycles
    // before any consumer. The export toggle keeps its original timing.
    reg evt_q = 1'b0;
    reg d_zero_q = 1'b0, d_border_q = 1'b0, d_lead_q = 1'b0, d_step_q = 1'b0;
    reg d_phlast_q = 1'b0, d_linelast_q = 1'b0;
    always @(posedge clk_pixel) begin
        cy_prev_px_r    <= cy0_r;
        cy_changed_px_r <= (cy0_r != cy_prev_px_r);
        cy_zero_px_r    <= (cy0_r == 11'd0);
        // decision stage (values as the tracker used to read them)
        evt_q        <= cy_changed_px_r;
        d_zero_q     <= cy_zero_px_r;
        d_border_q   <= !cy_zero_px_r && at_border_nxt_r;
        d_lead_q     <= !cy_zero_px_r && !at_border_nxt_r && at_lead_nxt_r;
        d_step_q     <= !cy_zero_px_r && !at_border_nxt_r && !at_lead_nxt_r && v_active_px_r;
        d_phlast_q   <= (v_phase_px_r == 3'(V_SCALE-1));
        d_linelast_q <= fb_line_last_r;
        if (evt_q) begin
            if (d_zero_q) begin
                v_active_px_r   <= 1'b0;
                v_approach_px_r <= 1'b0;
                v_phase_px_r    <= 3'd0;
                fb_line_px_r    <= 9'd0;
            end else if (d_border_q) begin
                v_active_px_r   <= 1'b1;
                v_approach_px_r <= 1'b0;
                v_phase_px_r    <= 3'd0;
                fb_line_px_r    <= 9'd0;
            end else if (d_lead_q) begin
                v_approach_px_r <= 1'b1;
            end else if (d_step_q) begin
                if (d_phlast_q) begin
                    v_phase_px_r <= 3'd0;
                    if (d_linelast_q)
                        v_active_px_r <= 1'b0;
                    else
                        fb_line_px_r <= fb_line_px_r + 9'd1;
                end else begin
                    v_phase_px_r <= v_phase_px_r + 3'd1;
                end
            end
        end
        if (cy_changed_px_r)
            cy_toggle_px_r <= ~cy_toggle_px_r;
    end

    // Isolated export copy: the raw tracker register feeds a marginal
    // compare cone (cy0_r == v_border_px_r into the tracker CEs); letting
    // top-level consumers fan out from it pulls its placement and broke
    // that cone (-0.38 on the first try). The value is quasi-static
    // (mode switches only), so a registered copy is free.
    reg [10:0] v_border_q;
    always @(posedge clk_pixel) v_border_q <= v_border_px_r;
    assign v_scale_o  = 3'(V_SCALE);
    assign v_border_o = v_border_q;

    // CDC of the position bundle: the hold values are stable a full
    // clk_pixel cycle before the toggle flips (same handshake as the 480p
    // variant's cy CDC), so the 11-bit bundle transfers atomically.
    reg [8:0] fb_line_hold_px_r;
    reg       v_active_hold_px_r, v_approach_hold_px_r;
    always @(posedge clk_pixel) begin
        if (cy_changed_px_r) begin
            fb_line_hold_px_r    <= fb_line_px_r;
            v_active_hold_px_r   <= v_active_px_r;
            v_approach_hold_px_r <= v_approach_px_r;
        end
    end

    reg cy_tgl_sync1_r, cy_tgl_sync2_r, cy_tgl_sync3_r;
    reg [8:0] disp_line_sync_r;
    reg       disp_active_sync_r, disp_approach_sync_r;

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            cy_tgl_sync1_r <= 1'b0;
            cy_tgl_sync2_r <= 1'b0;
            cy_tgl_sync3_r <= 1'b0;
            disp_line_sync_r     <= 9'd0;
            disp_active_sync_r   <= 1'b0;
            disp_approach_sync_r <= 1'b0;
        end else begin
            cy_tgl_sync1_r <= cy_toggle_px_r;
            cy_tgl_sync2_r <= cy_tgl_sync1_r;
            cy_tgl_sync3_r <= cy_tgl_sync2_r;
            if (cy_tgl_sync3_r != cy_tgl_sync2_r) begin
                disp_line_sync_r     <= fb_line_hold_px_r;
                disp_active_sync_r   <= v_active_hold_px_r;
                disp_approach_sync_r <= v_approach_hold_px_r;
            end
        end
    end

    // =========================================================================
    // Read path / Line Fetch FSM — clk domain (54 MHz)
    // =========================================================================
    //
    // Reactive fetch: continuously checks whether a new line needs fetching
    // based on the CDC'd display position bundle. No counter, no frame
    // reset, no cy-change gating — conditions are evaluated every cycle in
    // FETCH_IDLE for immediate response.
    //
    // - When approaching the active area from vblank: prefetches line 0
    // - During active display of line N: prefetches line N+1
    // - last_fetched_line_r (sentinel 9'h1FF = invalid) prevents re-fetches
    // - Bank = target_line[0] (line parity); display reads bank fb_line[0]
    // - Natural pacing: the fetcher can't outrun the display because
    //   next_line == last_fetched prevents re-fetch of the same line.

    // Register fb_width/fb_height derivatives to break timing path from
    // use_vgc_r mux (only changes at vsync, 1-cycle latency is fine)
    reg [11:0] h_border_r;
    reg [10:0] v_border_r;
    reg [8:0]  fb_height_r;
    always @(posedge clk) begin
        h_border_r <= (12'(HDMI_WIDTH) - ({fb_width, 1'b0} + {1'b0, fb_width})) >> 1;
        v_border_r <= (11'(HDMI_HEIGHT) - ({fb_height, 2'b0} + {2'b0, fb_height})) >> 1;
        fb_height_r <= fb_height[8:0];
    end

    // Packed width: words per line (fb_width / 2), registered to break
    // timing path from use_vgc_r→fb_width mux (only changes at vsync)
    reg [10:0] packed_width_r;
    always @(posedge clk) begin
        packed_width_r <= {1'b0, fb_width[10:1]};
    end
    // FB_READ_BURST_WORDS is now a module parameter (set from top.sv)

    // Pipelined fetch: issue side and receive side run independently within
    // FETCH_RUN. The CDC request FIFO holds 2 requests, so the next burst is
    // issued while the previous one's beats are still in flight — overlapping
    // the async-CDC round-trip latency that previously serialized every
    // burst (~28 cycles per 4 words ≈ 44µs per 320-word SHR line, marginal
    // against the 63.5µs scanline budget under write contention).
    // ISSUE_SPACING keeps a minimum gap between issues so the request queue
    // drains periodically and lower-priority arbiter ports (VGC source
    // reads, CPU shadow writes, DOC) are not starved during a line fetch.
    localparam FETCH_IDLE    = 1'b0;
    localparam FETCH_RUN     = 1'b1;
    assign fetch_active_o = (fetch_state_r == FETCH_RUN);
    localparam ISSUE_SPACING = 8;

    reg        fetch_state_r;
    reg [8:0]  last_fetched_line_r;  // 9'h1FF = invalid sentinel
    reg [10:0] fetch_word_r;         // Receive side: words received this line
    reg [10:0] issue_word_r;         // Issue side: words requested this line
    reg [20:0] issue_addr_r;         // Issue side: next request address
    reg [3:0]  in_flight_beats_r;    // Beats requested but not yet received
    reg [3:0]  issue_spacing_r;      // Min-spacing countdown between issues
    reg [20:0] fetch_line_base_r;   // Base addr of current/last fetched line
    localparam BANK_BITS = $clog2(LINE_BANKS);
    reg [BANK_BITS-1:0] fetch_bank_r;

    // Double-buffer: read buffer offset, latched at display frame start
    // so it stays stable for the entire display frame.
    reg [20:0] rd_buf_offset_r;

    // Debug counters (saturating, reset each frame at fb_vsync)
    reg [7:0] dbg_fifo_highwater_r;
    reg [7:0] dbg_fifo_overflow_r;
    reg [7:0] dbg_fetch_start_r;
    reg [7:0] dbg_fetch_done_r;
    reg [7:0] dbg_read_blocked_r;
    reg [7:0] dbg_yield_busy_r;
    reg [15:0] dbg_fifo_pop_r;    // Successful FIFO drains (writes sent to DDR3) per frame
    reg [15:0] dbg_fifo_push_r;   // FIFO pushes (128-bit words written) per frame
    reg [7:0] dbg_late_line_r;
    reg       late_line_prev_r;
    reg [7:0] dbg_line_not_ready_r;
    reg [7:0] dbg_line_lag_max_r;
    // Latched previous-frame finals — live counters reset each frame, so
    // reading them on the overlay misses brief spikes. These hold a stable
    // value for a full frame.
    reg [7:0] dbg_line_not_ready_frame_r;
    reg [7:0] dbg_line_lag_frame_r;
    // Cumulative not-ready events since reset (sticky, saturating) — catches
    // rare events between overlay glances.
    reg [7:0] dbg_line_not_ready_total_r;
    reg [7:0] dbg_ready_phase_err_r;
    reg [7:0] dbg_rd_fifo_max_r;
    reg [7:0] dbg_rd_fifo_drop_r;
    reg [7:0] dbg_vsync_raw_r;
    reg [7:0] dbg_frame_start_accept_r;
    reg [7:0] dbg_frame_start_reject_r;
    reg [8:0] completed_line_r [0:LINE_BANKS-1];
    reg [8:0] display_line_prev_r;
    reg       display_active_prev_r;

    // Display position in clk domain (CDC'd bundle from the pixel-domain
    // tracker — already in source-line space, no arithmetic here)
    wire [8:0] display_fb_line_w = disp_line_sync_r;
    wire       display_in_active_w = disp_active_sync_r;
    wire cy_approaching_active_w = disp_approach_sync_r && !disp_active_sync_r;

    // Decoupled fetch: next line = last fetched + 1 (never skips lines)
    wire [8:0] next_fetch_line_w = last_fetched_line_r + 9'd1;
    // Bank guard: don't write to bank the display is currently reading
    wire fetch_bank_safe_w = !display_in_active_w ||
                             (next_fetch_line_w[BANK_BITS-1:0] != display_fb_line_w[BANK_BITS-1:0]);
    // Prefetch limit: during vblank fill all LINE_BANKS banks, during active
    // stay <= LINE_BANKS-1 ahead
    wire [8:0] prefetch_limit_w = display_in_active_w ?
        (display_fb_line_w + 9'(LINE_BANKS)) : 9'(LINE_BANKS);
    wire prefetch_ok_w = (next_fetch_line_w < prefetch_limit_w);

    // Issue-side burst sizing and occupancy guard. The occupancy check
    // bounds (rd_fifo fill + beats in flight + this burst) to the rd_fifo
    // depth so response beats can never be dropped on a full rd_fifo.
    wire [10:0] issue_words_left_w = packed_width_r - issue_word_r;
    wire issue_burst_w = (issue_words_left_w >= FB_READ_BURST_WORDS[10:0]);
    wire [3:0] issue_beats_w = issue_burst_w ? 4'(FB_READ_BURST_WORDS) : 4'd1;
    wire issue_pending_w = (issue_word_r != packed_width_r);
    // KEEP AT 1. 2-outstanding CDC requests (SERIALIZE_FETCH=0) corrupt
    // read data on GW5AT silicon: beat counts stay balanced (verified by
    // the beat_extra/beat_timeout detectors reading 00 during corruption)
    // but chained requests return the PREVIOUS request's data — RTL
    // analysis and STA are both clean, cause unresolved. Throughput is
    // instead gained via 8-word bursts (READ_BURST8_PORT in ddr3_ports):
    // one ordinary serialized request fetches two 128-bit words.
    localparam SERIALIZE_FETCH = 1;
    wire issue_ok_w = (fetch_state_r == FETCH_RUN) &&
                      issue_pending_w &&
                      (SERIALIZE_FETCH == 0 || in_flight_beats_r == 4'd0) &&
                      (issue_spacing_r == 4'd0) &&
                      !fifo_busy_w &&
                      fb_read_port.available &&
                      ({1'b0, rd_fifo_count} + {2'b0, in_flight_beats_r} +
                       {2'b0, issue_beats_w} <= 6'(RD_FIFO_DEPTH));
    // Drop occurs when the 4th pair (completing a 128-bit word) can't push to FIFO
    wire wr_drop_w = fb_we_r && wr_x_r[0] && (wr_accum_slot_r == 2'd3) && fifo_full_w;
    wire [8:0] completed_line_for_display_w = completed_line_r[display_fb_line_w[BANK_BITS-1:0]];
    wire line_ready_w = (completed_line_for_display_w == display_fb_line_w);
    wire [8:0] line_lag_w = (completed_line_for_display_w == 9'h1FF ||
                             completed_line_for_display_w >= display_fb_line_w) ?
                             9'd0 : (display_fb_line_w - completed_line_for_display_w);
    wire [7:0] line_lag_clamped_w = line_lag_w[8] ? 8'hFF : line_lag_w[7:0];
    wire display_line_step_w = display_in_active_w &&
                               (!display_active_prev_r || (display_fb_line_w != display_line_prev_r));
    wire ready_phase_err_w = fb_read_port.ready && (fetch_state_r != FETCH_RUN);
    wire late_line_w = display_in_active_w &&
                       (display_fb_line_w != 9'd0) &&
                       (last_fetched_line_r != 9'h1FF) &&
                       (last_fetched_line_r < display_fb_line_w);
    // One-shot guard: without it, after prefetching lines 0-7 in the
    // approach window, prefetch_ok_w blocks line 8 and the line-0 condition
    // (last_fetched != 0) retriggers — looping refetches of lines 0-7 that
    // hog the DDR3 port for the entire approach window.
    reg line0_prefetched_r;
    wire fetch_start_line0_w = (fetch_state_r == FETCH_IDLE) &&
                               cy_approaching_active_w &&
                               !line0_prefetched_r &&
                               (last_fetched_line_r != 9'd0) &&
                               px_empty;
    // Catch-up: if the fetcher has fallen behind the display (port
    // contention), skip lines the display already passed instead of
    // fetching them late. Without this, the bank guard locks the fetcher
    // into permanent lag-1 lockstep: it can never fetch the line the
    // display is on, so every line completes one line too late and the
    // display reads 8-line-stale bank content for the rest of the frame.
    // Skipped lines display stale data once — they were already lost.
    wire fetch_catchup_w = (fetch_state_r == FETCH_IDLE) &&
                           !fetch_start_line0_w &&
                           display_in_active_w &&
                           (last_fetched_line_r != 9'h1FF) &&
                           (next_fetch_line_w <= display_fb_line_w) &&
                           (next_fetch_line_w < fb_height_r);
    wire fetch_start_next_w = (fetch_state_r == FETCH_IDLE) &&
                              !fetch_start_line0_w &&
                              !fetch_catchup_w &&
                              (display_in_active_w || cy_approaching_active_w) &&
                              (next_fetch_line_w < fb_height_r) &&
                              (next_fetch_line_w != last_fetched_line_r) &&
                              fetch_bank_safe_w &&
                              prefetch_ok_w &&
                              px_empty;
    wire fetch_start_pulse_w = fetch_start_line0_w || fetch_start_next_w;
    wire fetch_done_pulse_w = (fetch_state_r == FETCH_RUN) &&
                              fb_read_port.ready &&
                              (fetch_word_r == packed_width_r - 11'd1);

    // Per-frame debug counters and live high-water tracking
    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            dbg_fifo_highwater_r <= 8'd0;
            dbg_fifo_overflow_r <= 8'd0;
            dbg_fetch_start_r <= 8'd0;
            dbg_fetch_done_r <= 8'd0;
            dbg_read_blocked_r <= 8'd0;
            dbg_yield_busy_r <= 8'd0;
            dbg_fifo_pop_r <= 16'd0;
            dbg_fifo_push_r <= 16'd0;
            dbg_late_line_r <= 8'd0;
            late_line_prev_r <= 1'b0;
            dbg_line_not_ready_r <= 8'd0;
            dbg_line_lag_max_r <= 8'd0;
            dbg_line_not_ready_frame_r <= 8'd0;
            dbg_line_lag_frame_r <= 8'd0;
            dbg_line_not_ready_total_r <= 8'd0;
            dbg_ready_phase_err_r <= 8'd0;
            dbg_rd_fifo_max_r <= 8'd0;
            dbg_rd_fifo_drop_r <= 8'd0;
            dbg_vsync_raw_r <= 8'd0;
            dbg_frame_start_accept_r <= 8'd0;
            dbg_frame_start_reject_r <= 8'd0;
            for (int cb = 0; cb < LINE_BANKS; cb++)
                completed_line_r[cb] <= 9'h1FF;
            display_line_prev_r <= 9'd0;
            display_active_prev_r <= 1'b0;
        end else if (frame_start_w) begin
            dbg_fifo_highwater_r <= fifo_count_clamped_w;
            dbg_fifo_overflow_r <= 8'd0;
            dbg_fetch_start_r <= 8'd0;
            dbg_fetch_done_r <= 8'd0;
            dbg_read_blocked_r <= 8'd0;
            dbg_yield_busy_r <= 8'd0;
            dbg_fifo_pop_r <= 16'd0;
            dbg_fifo_push_r <= 16'd0;
            dbg_late_line_r <= 8'd0;
            late_line_prev_r <= 1'b0;
            // Latch previous frame's finals before clearing the live counters
            dbg_line_not_ready_frame_r <= dbg_line_not_ready_r;
            dbg_line_lag_frame_r <= dbg_line_lag_max_r;
            dbg_line_not_ready_r <= 8'd0;
            dbg_line_lag_max_r <= 8'd0;
            dbg_ready_phase_err_r <= 8'd0;
            dbg_rd_fifo_max_r <= 8'd0;
            dbg_rd_fifo_drop_r <= 8'd0;
            dbg_vsync_raw_r <= 8'd1;
            dbg_frame_start_accept_r <= 8'd1;
            dbg_frame_start_reject_r <= 8'd0;
            // NOTE: completed_line_r is deliberately NOT reset here.
            // frame_start_w is the WRITE-side (Apple-domain) vsync, async to
            // the HDMI raster — wiping read-side bank bookkeeping mid-display
            // made line_not_ready count ~8 false events per frame and forced
            // line_lag to 0 via the sentinel. The banks still hold valid line
            // data across write-frame boundaries; completed_line_r tracks
            // which line each bank holds, which stays true regardless of
            // write-side frame phase. display_line_prev_r/display_active_prev_r
            // are likewise display-side state and keep running.
        end else begin
            if (fb_vsync_r) begin
                if (dbg_vsync_raw_r != 8'hFF)
                    dbg_vsync_raw_r <= dbg_vsync_raw_r + 8'd1;
                if (dbg_frame_start_reject_r != 8'hFF)
                    dbg_frame_start_reject_r <= dbg_frame_start_reject_r + 8'd1;
            end

            if (fifo_count_clamped_w > dbg_fifo_highwater_r)
                dbg_fifo_highwater_r <= fifo_count_clamped_w;

            if (wr_drop_w && dbg_fifo_overflow_r != 8'hFF)
                dbg_fifo_overflow_r <= dbg_fifo_overflow_r + 8'd1;

            // Count successful FIFO pushes (accumulator completing a 128-bit word)
            if (fb_we_r && wr_x_r[0] && (wr_accum_slot_r == 2'd3) && !fifo_full_w && dbg_fifo_push_r != 16'hFFFF)
                dbg_fifo_push_r <= dbg_fifo_push_r + 16'd1;

            if (fetch_start_pulse_w && dbg_fetch_start_r != 8'hFF)
                dbg_fetch_start_r <= dbg_fetch_start_r + 8'd1;

            if (fetch_done_pulse_w && dbg_fetch_done_r != 8'hFF)
                dbg_fetch_done_r <= dbg_fetch_done_r + 8'd1;

            if (fifo_pop_w && dbg_fifo_pop_r != 16'hFFFF)
                dbg_fifo_pop_r <= dbg_fifo_pop_r + 16'd1;

            if ((fetch_state_r == FETCH_RUN) && issue_pending_w &&
                fifo_busy_w && dbg_yield_busy_r != 8'hFF)
                dbg_yield_busy_r <= dbg_yield_busy_r + 8'd1;

            if ((fetch_state_r == FETCH_RUN) && issue_pending_w && !fifo_busy_w &&
                !fb_read_port.available && dbg_read_blocked_r != 8'hFF)
                dbg_read_blocked_r <= dbg_read_blocked_r + 8'd1;

            if (late_line_w && !late_line_prev_r && dbg_late_line_r != 8'hFF)
                dbg_late_line_r <= dbg_late_line_r + 8'd1;

            late_line_prev_r <= late_line_w;

            if (fetch_done_pulse_w)
                completed_line_r[last_fetched_line_r[BANK_BITS-1:0]] <= last_fetched_line_r;

            if (display_line_step_w && !line_ready_w) begin
                if (dbg_line_not_ready_r != 8'hFF)
                    dbg_line_not_ready_r <= dbg_line_not_ready_r + 8'd1;
                if (dbg_line_not_ready_total_r != 8'hFF)
                    dbg_line_not_ready_total_r <= dbg_line_not_ready_total_r + 8'd1;
            end

            if (display_in_active_w && (line_lag_clamped_w > dbg_line_lag_max_r))
                dbg_line_lag_max_r <= line_lag_clamped_w;

            if (ready_phase_err_w && dbg_ready_phase_err_r != 8'hFF)
                dbg_ready_phase_err_r <= dbg_ready_phase_err_r + 8'd1;

            // rd_fifo diagnostics: peak fill and dropped beats
            if ({3'd0, rd_fifo_count} > dbg_rd_fifo_max_r)
                dbg_rd_fifo_max_r <= {3'd0, rd_fifo_count};
            if (lb_wr_w && rd_fifo_count[RD_FIFO_ADDR_BITS] && dbg_rd_fifo_drop_r != 8'hFF)
                dbg_rd_fifo_drop_r <= dbg_rd_fifo_drop_r + 8'd1;

            if (display_in_active_w)
                display_line_prev_r <= display_fb_line_w;
            display_active_prev_r <= display_in_active_w;
        end
    end

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            fetch_state_r <= FETCH_IDLE;
            last_fetched_line_r <= 9'h1FF;
            fetch_word_r <= 11'd0;
            issue_word_r <= 11'd0;
            issue_addr_r <= 21'd0;
            in_flight_beats_r <= 4'd0;
            issue_spacing_r <= 4'd0;
            fetch_line_base_r <= 21'd0;
            fetch_bank_r <= '0;
            rd_buf_offset_r <= 21'd0;
            line0_prefetched_r <= 1'b0;
        end else begin
            // Rearm the one-shot line-0 prefetch once the approach window
            // ends (display enters active, or mode change moves the border).
            if (!cy_approaching_active_w)
                line0_prefetched_r <= 1'b0;

            case (fetch_state_r)

            FETCH_IDLE: begin
                // Check every cycle — no cy_changed gate needed.
                // last_fetched_line_r prevents redundant fetches.
                // px_empty gate: must wait for pixel extraction to finish so
                // fetch_start_pulse_w fires and resets rd_fifo/lb_wr_pixel_x.
                // Without this, lb_wr_pixel_x carries over from the previous
                // line and pixels are written to wrong line buffer positions.
                if (fetch_start_line0_w) begin
                    // Approaching active area — prefetch line 0
                    // Latch read buffer: the buffer the writer last
                    // COMPLETED. (Was "opposite of the writer's current
                    // buffer" — wrong whenever the writer is idle between
                    // frames: the display then picked the buffer the
                    // writer took next and tore one frame later; a2p25
                    // bench 10-11, fixed-phase 60 Hz renderer, stripe
                    // stepped at 1/8 down every frame.)
                    rd_buf_offset_r <= frame_done_parity_r ? BUFFER_OFFSET : 21'd0;
                    last_fetched_line_r <= 9'd0;
                    line0_prefetched_r <= 1'b1;
                    fetch_bank_r <= '0;
                    fetch_word_r <= 11'd0;
                    issue_word_r <= 11'd0;
                    in_flight_beats_r <= 4'd0;
                    issue_spacing_r <= 4'd0;
                    fetch_line_base_r <= 21'd0;
                    issue_addr_r <= 21'd0;
                    fetch_state_r <= FETCH_RUN;
                end else if (fetch_catchup_w) begin
                    // Behind the display — skip one line per cycle (no fetch)
                    // until next_fetch_line_w is back ahead of the display.
                    last_fetched_line_r <= next_fetch_line_w;
                    fetch_line_base_r <= fetch_line_base_r + {10'd0, packed_width_r};
                end else if (fetch_start_next_w) begin
                    // Decoupled sequential fetch: always fetch last+1
                    // Use incremental addition instead of multiplication
                    // (packed_width_r only changes at vsync so this is always correct)
                    last_fetched_line_r <= next_fetch_line_w;
                    fetch_bank_r <= next_fetch_line_w[BANK_BITS-1:0];
                    fetch_word_r <= 11'd0;
                    issue_word_r <= 11'd0;
                    in_flight_beats_r <= 4'd0;
                    issue_spacing_r <= 4'd0;
                    fetch_line_base_r <= fetch_line_base_r + {10'd0, packed_width_r};
                    issue_addr_r <= fetch_line_base_r + {10'd0, packed_width_r};
                    fetch_state_r <= FETCH_RUN;
                end
            end

            FETCH_RUN: begin
                // Issue side: queue the next burst into the CDC request FIFO
                // while previous beats are still in flight. issue_ok_w gates
                // on port availability, write-FIFO yield, occupancy, and the
                // fairness spacing counter.
                if (issue_ok_w) begin
                    issue_word_r <= issue_word_r + {7'd0, issue_beats_w};
                    issue_addr_r <= issue_addr_r + {17'd0, issue_beats_w};
                    issue_spacing_r <= 4'(ISSUE_SPACING);
                end else if (issue_spacing_r != 4'd0) begin
                    issue_spacing_r <= issue_spacing_r - 4'd1;
                end

                // In-flight beat tracking (issue and receive can coincide).
                // The subtraction is clamped: a spurious/duplicate beat (it
                // is counted by the beat-extra detector) must not underflow
                // the counter to 15 and wedge the occupancy guard.
                in_flight_beats_r <= in_flight_beats_r
                                     + (issue_ok_w ? issue_beats_w : 4'd0)
                                     - ((fb_read_port.ready &&
                                         (in_flight_beats_r != 4'd0 || issue_ok_w)) ? 4'd1 : 4'd0);

                // Receive side: count beats; line complete when all received
                if (fb_read_port.ready) begin
                    if (fetch_word_r == packed_width_r - 11'd1)
                        fetch_state_r <= FETCH_IDLE;
                    else
                        fetch_word_r <= fetch_word_r + 11'd1;
                end
            end

            default: fetch_state_r <= FETCH_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Beat-balance detectors (sticky, never reset except by rst_n)
    // =========================================================================
    // Discriminates the two failure modes of the multi-outstanding read path:
    //   - dbg_beat_extra_r: a ready beat arrived when no beat was expected
    //     (state != FETCH_RUN, or in_flight == 0). Nonzero = the arbiter/CDC
    //     DUPLICATED a request or delivered beats late across a line boundary.
    //   - dbg_beat_timeout_r: beats outstanding but none arrived for ~19µs
    //     (1024 cycles; legitimate latency is <1µs). Nonzero = a request or
    //     its response was LOST.
    reg [7:0]  dbg_beat_extra_r;
    reg [7:0]  dbg_beat_timeout_r;
    reg [10:0] beat_wait_cnt_r;
    wire beat_unexpected_w = fb_read_port.ready &&
                             ((fetch_state_r != FETCH_RUN) || (in_flight_beats_r == 4'd0));

    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            dbg_beat_extra_r <= 8'd0;
            dbg_beat_timeout_r <= 8'd0;
            beat_wait_cnt_r <= 11'd0;
        end else begin
            if (beat_unexpected_w && dbg_beat_extra_r != 8'hFF)
                dbg_beat_extra_r <= dbg_beat_extra_r + 8'd1;

            if ((fetch_state_r == FETCH_RUN) && (in_flight_beats_r != 4'd0) &&
                !fb_read_port.ready) begin
                beat_wait_cnt_r <= beat_wait_cnt_r + 11'd1;
                if (beat_wait_cnt_r == 11'h7FF) begin
                    beat_wait_cnt_r <= 11'd0;
                    if (dbg_beat_timeout_r != 8'hFF)
                        dbg_beat_timeout_r <= dbg_beat_timeout_r + 8'd1;
                end
            end else begin
                beat_wait_cnt_r <= 11'd0;
            end
        end
    end

    assign dbg_beat_extra_o = dbg_beat_extra_r;
    assign dbg_beat_timeout_o = dbg_beat_timeout_r;

    // Drive read port (issue side)
    assign fb_read_port.addr    = issue_addr_r + rd_buf_offset_r;
    assign fb_read_port.data    = 32'd0;
    assign fb_read_port.byte_en = 4'b1111;
    assign fb_read_port.wr      = 1'b0;
    assign fb_read_port.rd      = issue_ok_w;
    assign fb_read_port.burst   = issue_burst_w;

    assign dbg_fifo_level_o = fifo_count_clamped_w;
    assign dbg_fifo_highwater_o = dbg_fifo_highwater_r;
    assign dbg_fifo_overflow_o = dbg_fifo_overflow_r;
    assign dbg_fetch_start_o = dbg_fetch_start_r;
    assign dbg_fetch_done_o = dbg_fetch_done_r;
    assign dbg_read_blocked_o = dbg_read_blocked_r;
    assign dbg_yield_busy_o = dbg_yield_busy_r;
    assign dbg_fifo_pop_o = dbg_fifo_pop_r[15:8];   // Upper byte: count / 256
    assign dbg_fifo_push_o = dbg_fifo_push_r[15:8]; // Upper byte: count / 256
    assign dbg_late_line_o = dbg_late_line_r;
    assign dbg_line_not_ready_o = dbg_line_not_ready_frame_r;
    assign dbg_line_lag_max_o = dbg_line_lag_frame_r;
    assign dbg_line_not_ready_total_o = dbg_line_not_ready_total_r;
    assign dbg_ready_phase_err_o = dbg_ready_phase_err_r;
    assign dbg_rd_fifo_max_o = dbg_rd_fifo_max_r;
    assign dbg_rd_fifo_drop_o = dbg_rd_fifo_drop_r;
    assign dbg_vsync_raw_o = dbg_vsync_raw_r;
    assign dbg_frame_start_accept_o = dbg_frame_start_accept_r;
    assign dbg_frame_start_reject_o = dbg_frame_start_reject_r;
    assign dbg_flags_o = {
        fifo_full_w,                 // [7]
        fifo_busy_w,                 // [6]
        (fetch_state_r != FETCH_IDLE), // [5]
        fb_read_port.available,      // [4]
        fb_read_port.ready,          // [3]
        fb_write_port.available,     // [2]
        (dbg_fifo_overflow_r != 8'd0), // [1]
        (dbg_line_not_ready_r != 8'd0) // [0]
    };

    // =========================================================================
    // Line Buffer — 1 pixel per entry (matches DDR3 architecture)
    // =========================================================================
    //
    // Single BRAM array: 8 banks x 1024 entries x 18 bits (RGB666).
    // Write port: clk (54 MHz) — serialized memory read responses
    // Read port: clk_pixel (27 MHz) — HDMI pixel output
    //
    // Stores 1 pixel per entry, serializing the 2-pixel words through a
    // small buffer on the write side.

    // Stored as RGB565 (the memory format, converted back on the read side):
    // LINE_BANKS x 1024 x 16 = LINE_BANKS BSRAM blocks (x18 would need one
    // more per 8 banks — a2p25 GW5A-25 fit, 10-11).
    reg [15:0] line_buf [0:LINE_BANKS*1024-1] /* synthesis syn_ramstyle="block_ram" */;

    // ---- Write side (clk domain, 54 MHz) ----
    // Each 32-bit word contains 2 packed RGB565 pixels.
    // Ready can pulse on consecutive cycles during burst reads,
    // so we buffer pixels and drain 1 per cycle to the single-port BRAM.

    wire lb_wr_w = fb_read_port.ready && (fetch_state_r == FETCH_RUN);

    // ---- Read FIFO: buffer raw 32-bit words (single write port) ----
    // 16 deep: holds one full 8-word burst plus extraction backlog, so the
    // next burst can be issued while the previous one drains (occupancy
    // guard in issue_ok_w enforces no-overflow).
    localparam RD_FIFO_DEPTH = 16;
    localparam RD_FIFO_ADDR_BITS = 4;
    reg [31:0] rd_fifo [0:RD_FIFO_DEPTH-1];
    reg [RD_FIFO_ADDR_BITS:0] rd_fifo_wr_ptr, rd_fifo_rd_ptr;
    wire [RD_FIFO_ADDR_BITS:0] rd_fifo_count = rd_fifo_wr_ptr - rd_fifo_rd_ptr;
    wire rd_fifo_empty = (rd_fifo_wr_ptr == rd_fifo_rd_ptr);

    // Response handler: pop 32-bit words and write 2 pixels sequentially.
    reg [31:0] rd_word_latched_r;
    reg        rd_pixel_idx_r;      // 0 = even pixel [15:0], 1 = odd pixel [31:16]
    reg        rd_pixel_active_r;
    wire rd_fifo_push = lb_wr_w && !rd_fifo_count[RD_FIFO_ADDR_BITS];
    wire px_empty = rd_fifo_empty && !rd_pixel_active_r;
    reg [10:0] lb_wr_pixel_x;

    // Push 1 word per ready pulse
    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            rd_fifo_wr_ptr <= '0;
        end else if (fetch_start_pulse_w) begin
            rd_fifo_wr_ptr <= '0;
        end else if (rd_fifo_push) begin
            rd_fifo[rd_fifo_wr_ptr[RD_FIFO_ADDR_BITS-1:0]] <= fb_read_port.q;
            rd_fifo_wr_ptr <= rd_fifo_wr_ptr + 1;
        end
    end

    // Pop + extract: latch word, then write 2 pixels sequentially to line buffer.
    // Even pixel (bits [15:0]) first, then odd pixel (bits [31:16]).
    // RGB565→RGB666 conversion at extraction time.
    always @(posedge clk or negedge rst_n_clk) begin
        if (!rst_n_clk) begin
            rd_fifo_rd_ptr <= '0;
            rd_word_latched_r <= 32'd0;
            rd_pixel_idx_r <= 1'b0;
            rd_pixel_active_r <= 1'b0;
            lb_wr_pixel_x <= 11'd0;
        end else if (fetch_start_pulse_w) begin
            rd_fifo_rd_ptr <= '0;
            rd_pixel_idx_r <= 1'b0;
            rd_pixel_active_r <= 1'b0;
            lb_wr_pixel_x <= 11'd0;
        end else if (rd_pixel_active_r) begin
            // Extract pixel from latched word and write to line buffer
            line_buf[{fetch_bank_r, lb_wr_pixel_x[9:0]}] <=
                (TEST_PATTERN == 1) ? rgb666_to_565(test_pixel(lb_wr_pixel_x[9:0])) :
                rd_pixel_idx_r ? rd_word_latched_r[31:16] :
                                 rd_word_latched_r[15:0];
            lb_wr_pixel_x <= lb_wr_pixel_x + 11'd1;
            if (rd_pixel_idx_r)
                rd_pixel_active_r <= 1'b0;
            rd_pixel_idx_r <= ~rd_pixel_idx_r;
        end else if (!rd_fifo_empty && TEST_PATTERN != 5) begin
            // Pop next word from FIFO and start pixel extraction
            rd_word_latched_r <= rd_fifo[rd_fifo_rd_ptr[RD_FIFO_ADDR_BITS-1:0]];
            rd_fifo_rd_ptr <= rd_fifo_rd_ptr + 1;
            rd_pixel_idx_r <= 1'b0;
            rd_pixel_active_r <= 1'b1;
        end
    end

    // TEST_PATTERN==5: memory bypass — write fb_data directly to line buffer.
    // Bypasses FIFO, memory, px_buf entirely. Tests line buffer + display pipeline
    // in isolation from the memory round-trip.
    //
    // Sync strategy: use frame_start_w (scan_timer vsync) for frame boundaries,
    // but defer the reset until a clean line boundary (bypass_x_r wraps) to
    // avoid mid-line x corruption. The scan_timer and HDMI display have
    // slightly different frame rates (~59.94 Hz vs ~60.0 Hz), causing a slow
    // vertical scroll (~1 full cycle every ~17 seconds). This is an inherent
    // limitation of the 2-bank line buffer without full-frame storage — the
    // scroll confirms the line buffer + display pipeline is clean.
    generate if (TEST_PATTERN == 5) begin : gen_bypass
        reg [10:0] bypass_x_r;
        reg [8:0]  bypass_y_r;
        reg        bp_sync_pending_r;

        always @(posedge clk or negedge rst_n_clk) begin
            if (!rst_n_clk) begin
                bypass_x_r <= 11'd0;
                bypass_y_r <= 9'd0;
                bp_sync_pending_r <= 1'b0;
            end else begin
                // Mark frame sync pending on scan_timer vsync
                if (frame_start_w)
                    bp_sync_pending_r <= 1'b1;

                if (fb_we_r) begin
                    line_buf[{bypass_y_r[BANK_BITS-1:0], bypass_x_r[9:0]}] <= rgb666_to_565(fb_data_r);
                    if (bypass_x_r == fb_width - 11'd1) begin
                        bypass_x_r <= 11'd0;
                        // Apply frame sync at clean line boundary only
                        if (bp_sync_pending_r) begin
                            bypass_y_r <= 9'd0;
                            bp_sync_pending_r <= 1'b0;
                        end else begin
                            bypass_y_r <= bypass_y_r + 9'd1;
                        end
                    end else begin
                        bypass_x_r <= bypass_x_r + 11'd1;
                    end
                end
            end
        end
    end endgenerate

    // ---- Read side (clk_pixel domain, 27 MHz) ----
    // Bank = line[2:0], computed directly from hdmi_cy — no CDC needed.
    // Bank = fb_line[2:0] from the pixel-domain vertical tracker (x5
    // vertical scaling handled there; no per-pixel arithmetic here)
    wire [BANK_BITS-1:0] rd_bank_w = fb_line_px_r[BANK_BITS-1:0];

    // =========================================================================
    // Output path — clk_pixel domain (27 MHz)
    // =========================================================================

    reg [10:0] fb_width_px_r;
    reg [9:0]  fb_height_px_r;
    reg [11:0] h_border_px_r;
    // (v_border_px_r declared above, next to the vertical tracker)

    always @(posedge clk_pixel) begin
        fb_width_px_r <= fb_width;
        fb_height_px_r <= fb_height;
        h_border_px_r <= (12'(HDMI_WIDTH) - ({fb_width, 1'b0} + {1'b0, fb_width})) >> 1;
        v_border_px_r <= (11'(HDMI_HEIGHT) - ({fb_height, 2'b0} + {2'b0, fb_height})) >> 1;
    end

    wire in_v_active_px_w = v_active_px_r;

    // EXP 20: Explicit BSRAM read register + pipeline alignment.
    //
    // The line buffer is inferred as BSRAM (syn_ramstyle="block_ram"), which has
    // synchronous reads — but the original code used a wire assignment
    // (line_buf[addr]) that implies async read. This mismatch causes:
    //   1) Ambiguous read-port clock selection by the synthesizer
    //   2) Unconstrained timing path from address to data
    //   3) in_active_px_r 1 cycle ahead of pixel data
    //
    // Fix: explicitly register the BSRAM read output on clk_pixel, and delay
    // the control signals to match.

    // Horizontal tracker for the pixel at cx+4 (the 4-cycle read pipeline
    // lookahead — timing round 2 cone (i) added the address-copy stage
    // 1b below): H_SCALE phase + source-x advance incrementally from the
    // one-shot equality trigger at the left border — no divider, no wide
    // subtract in the address path.
    // Trigger pre-registered one cycle earlier (cx == border-LEAD at cycle N
    // implies cx == border-(LEAD-1) at N+1; cx is monotonic). The 12-bit
    // equality then never appears in the address/CE cone, and the
    // compare target is a registered constant (h_trigger_x_px_r).
    // The trigger X is computed modulo the raster line: with a 640-wide
    // source the active window spans the full 1920 and h_border is 0, so
    // the +5 lookahead lands in the previous line's blanking (cx = 2195).
    // The earlier "cx0_r + 5 == h_border" form could never match there —
    // IIgs SHR frames scanned out black while the framebuffer held the
    // rendered image (a2p25 10-11; the a2mega shares this read side).
    // Apple geometry: 120 - H_TRIGGER_LEAD.
    // H_TRIGGER_LEAD: raster cycles between the trigger and the first
    // active pixel reaching the DP transmitter's rgb input, less the
    // transmitter's RGB_LATENCY (2). Counted 10-11 on the a2p25 (identical
    // chain on the a2mega): this module 6 (cx0_r, h_trigger_r, stage 1,
    // 1b, 2, 3 — timing round 2 cone (i) added the 1b address copy, hence
    // 12 rather than the 11 counted on 10-11), then the top's composite 8
    // (fb_rgb_osd_r 1, osd_text_overlay 1, scanline_dim 0, DebugOverlay 6
    // — s0/sA/sB/s1/s2/output, ENABLE notwithstanding) = 14, minus 2 = 12.
    // UNVERIFIED on hardware after the merge: check the IIgs SHR left
    // edge (one 320-mode pixel of border colour = off by 6). The value had been 5 since the
    // 08-30 stage-3 split, from before the OSD/overlay stages existed in
    // this path: every frame scanned out 6 raster pixels late — invisible
    // inside the Apple modes' 120-px borders, but the borderless 640-wide
    // IIgs SHR frame showed 6 px (one 320-mode pixel) of border colour at
    // its left edge. Change the chain, change this number.
    reg [11:0] h_trigger_x_px_r;
    reg h_trigger_r;
    always @(posedge clk_pixel) begin
        h_trigger_x_px_r <= (h_border_px_r < 12'(H_TRIGGER_LEAD))
                              ? h_border_px_r + 12'(HDMI_H_TOTAL - H_TRIGGER_LEAD)
                              : h_border_px_r - 12'(H_TRIGGER_LEAD);
        h_trigger_r <= (cx0_r == h_trigger_x_px_r);
    end
    wire        h_trigger_w = h_trigger_r;

    reg        h_act_r;
    reg [1:0]  h_phase_r;
    reg [9:0]  fb_x_r;
    reg        h_act_n;
    reg [1:0]  h_phase_n;
    reg [9:0]  fb_x_n;

    // Timing round 2 cone (i2): the end-of-line test "fb_x_r ==
    // fb_width - 1" (subtract + 10-bit compare) sat inside lb_rd_addr's
    // CE cone (fb_width_px_r -> lb_rd_addr CE, +0.45 ns at 148.5 MHz).
    // fb_x_r takes fb_x_n every cycle, so the flag is registered from the
    // next value and is exact; fb_width is quasi-static (mode change).
    reg [9:0]  fb_width_m1_px_r = 10'd0;
    reg [9:0]  fb_width_m2_px_r = 10'd0;
    reg        x_last_r = 1'b0;

    always @* begin
        h_act_n   = h_act_r;
        h_phase_n = h_phase_r;
        fb_x_n    = fb_x_r;
        if (h_trigger_w) begin
            h_act_n   = 1'b1;
            h_phase_n = 2'd0;
            fb_x_n    = 10'd0;
        end else if (h_act_r) begin
            if (h_phase_r == 2'(H_SCALE-1)) begin
                h_phase_n = 2'd0;
                if (x_last_r)
                    h_act_n = 1'b0;
                else
                    fb_x_n = fb_x_r + 10'd1;
            end else begin
                h_phase_n = h_phase_r + 2'd1;
            end
        end
    end

    // Pipeline stage 1: address register + control flags (posedge N)
    reg [BANK_BITS+9:0] lb_rd_addr;
    reg in_active_s1_r;

    always @(posedge clk_pixel) begin
        h_act_r   <= h_act_n;
        h_phase_r <= h_phase_n;
        fb_x_r    <= fb_x_n;
        fb_width_m1_px_r <= fb_width_px_r[9:0] - 10'd1;
        fb_width_m2_px_r <= fb_width_px_r[9:0] - 10'd2;
        // 138B durability: the same next-value test written on the flag's
        // own algebra instead of on the fb_x_n mux — trigger: x becomes 0
        // (last iff width == 1); advance: x becomes x+1 (last iff x ==
        // width-2); otherwise x holds and so does the flag. Identical to
        // (fb_x_n == width-1) except during the one line in which the
        // width itself changes (mode switch), which the next trigger
        // reloads. Removes the mux from the compare cone (+0.07 on 138B).
        x_last_r <= h_trigger_w ? (fb_width_m1_px_r == 10'd0) :
                    (h_act_r && (h_phase_r == 2'(H_SCALE-1)) && !x_last_r)
                        ? (fb_x_r == fb_width_m2_px_r) : x_last_r;
        // No else-zero: the address is a don't-care outside the active
        // window (output muxes on in_active_px_r), and the zeroing put a
        // RESET arc on 13 flops at the end of the trigger cone.
        if (h_act_n && in_v_active_px_w)
            lb_rd_addr <= {rd_bank_w, fb_x_n};
        in_active_s1_r <= h_act_n && in_v_active_px_w;
    end

    // Pipeline stage 1b (timing round 2 cone (i)): a plain, CE-free copy of
    // the read address right before the BSRAM. lb_rd_addr carries a CE cone
    // (h_act_n && in_v_active), so the placer parks it by the walker logic —
    // far from the several BSRAM blocks the 8192-entry line buffer spans —
    // and "lb_rd_addr -> line_buf ADB" (routing + BSRAM address setup) sat
    // at +0.004..+0.303 across 60K rolls. This copy has no logic on either
    // side and can be placed at the blocks. +1 read latency, compensated by
    // the cx+4 lookahead / H_TRIGGER_LEAD above and the extra active-flag stage.
    (* syn_keep = 1, syn_preserve = 1 *) reg [BANK_BITS+9:0] lb_rd_addr_q;
    reg in_active_s1b_r;
    always @(posedge clk_pixel) begin
        lb_rd_addr_q    <= lb_rd_addr;
        in_active_s1b_r <= in_active_s1_r;
    end

    // Pipeline stage 2: BSRAM read register + delayed control (posedge N+2)
    // This gives the synthesizer a clear clk_pixel read clock for the BSRAM
    // and ensures deterministic 1-cycle read latency.
    reg [COLOR_BITS-1:0] lb_rd_data_r;
    reg in_active_px_r;

    always @(posedge clk_pixel) begin
        lb_rd_data_r <= (TEST_PATTERN == 2) ?
            test_pixel(lb_rd_addr_q[9:0]) : rgb565_to_666(line_buf[lb_rd_addr_q]);
        in_active_px_r <= in_active_s1b_r;
    end

    // Pipeline stage 3 (08-30 structural timing): register the BSRAM
    // read data and its aligned controls BEFORE the color-conversion
    // combinational chain. The BSRAM-DO -> torgb/mux/dim -> output-reg
    // path was the clk_pix critical family in both full cores (worst
    // -1.1 ns); this splits it with a pure register. The +1 cycle of
    // output latency is matched by the DP transmitter's RGB_LATENCY=2
    // pull contract (see dp_video_timing.v) — frame content unchanged.
    reg [COLOR_BITS-1:0] lb_rd_data_q;
    reg in_active_px_q;
    always @(posedge clk_pixel) begin
        lb_rd_data_q   <= lb_rd_data_r;
        in_active_px_q <= in_active_px_r;
    end

    // EXP 22: Binary threshold — non-zero pixel data → white, zero → black.
    // This makes ghost pixels maximally visible by eliminating color ambiguity.
    wire [23:0] active_rgb_w = (THRESHOLD_DIAG != 0) ?
        (lb_rd_data_q != {COLOR_BITS{1'b0}} ? 24'hFFFFFF : 24'h000000) :
        torgb(lb_rd_data_q);
    wire [23:0] border_rgb_w = torgb(rgb565_to_666(rgb666_to_565(border_color)));

    wire [23:0] pixel_rgb_w = in_active_px_q ? active_rgb_w : border_rgb_w;

    // Scanline dimming moved to the composite-level scanline_dim module.
    wire [23:0] final_rgb_w = sleep_i ? 24'd0 : pixel_rgb_w;

    assign r_o = final_rgb_w[23:16];
    assign g_o = final_rgb_w[15:8];
    assign b_o = final_rgb_w[7:0];

endmodule
