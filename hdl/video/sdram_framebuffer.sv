// SDRAM Framebuffer for Tang Nano 20K — 480p output
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
// SDRAM-backed framebuffer for the a2n20v2-GS board. Stores rendered Apple II
// video pixels in SDRAM and reads them back for 480p HDMI display.
//
// Architecture:
//   Write path: accepts fb_we/fb_data from renderers (apple_video_fb, vgc_fb),
//               converts RGB666 to RGB565, packs pixel pairs into 32-bit words,
//               buffers in a 256-entry FIFO, and drains to SDRAM via FB_WRITE_PORT.
//   Read path:  line fetch FSM prefetches scanlines from SDRAM into a dual-port
//               BRAM line buffer, unpacking 2 pixels per SDRAM word.
//               Yields to writes only when FIFO is near full (safety valve).
//   CDC:        only needed for the line buffer (54 MHz write, 27 MHz read)
//               using true dual-port BRAM with independent clocks.
//
// Pixel packing: 2x RGB565 per 32-bit SDRAM word halves SDRAM access count,
// solving the bandwidth contention between reads and writes that caused
// vertical artifacts with the original 1-pixel-per-word design.
//
// Display: 720x480 @ 59.94 Hz (VIDEO_ID_CODE=2)
//   Apple II modes: [80 border][560 active][80 border] x [48 border][384=192x2][48 border]
//   IIgs SHR modes: [40 border][640 active][40 border] x [40 border][400=200x2][40 border]
//   2x integer vertical scaling, optional scanline dimming on odd lines.
//

module sdram_framebuffer #(
    parameter COLOR_BITS = 18,           // RGB666
    // Base address offset applied by the memory arbiter (sdram_ports/ddr3_ports).
    // Test pattern modes:
    //   0 = normal (SDRAM data)
    //   1 = test pattern via line buffer (tests BRAM + display pipeline)
    //   2 = test pattern at output (bypasses BRAM entirely, tests display only)
    //   3 = test pattern at write packer input (tests full SDRAM round-trip)
    //   4 = 1-pixel alternating B/W stripes (mixed-color pair test)
    //   6 = frame-alternating solid color (stale-data/FIFO-drop detection)
    parameter TEST_PATTERN = 0,
    // EXP 22: Binary threshold diagnostic — all non-zero pixels become white,
    // zero pixels become black. Makes ghost artifacts maximally visible.
    parameter THRESHOLD_DIAG = 0
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

    // SDRAM port interfaces
    mem_port_if.client  fb_write_port,   // For writing pixels to SDRAM
    mem_port_if.client  fb_read_port,    // For reading scanlines from SDRAM

    // HDMI scan position (pixel clock domain, from HDMI encoder)
    input  logic [10:0] hdmi_cx,
    input  logic [9:0]  hdmi_cy,

    // Video output (pixel clock domain)
    output logic [7:0]  r_o,
    output logic [7:0]  g_o,
    output logic [7:0]  b_o,

    // Configuration
    input  logic [COLOR_BITS-1:0] border_color,
    input  logic        scanline_en,     // Enable CRT scanline dimming
    input  logic        sleep_i,         // Output black when high

    // Debug counters/flags (clk domain)
    output logic [7:0]  dbg_fifo_level_o,      // Current FIFO fill level (clamped)
    output logic [7:0]  dbg_fifo_highwater_o,  // Per-frame FIFO high-water mark
    output logic [7:0]  dbg_fifo_overflow_o,   // Dropped packed writes per frame
    output logic [7:0]  dbg_fetch_start_o,     // Line fetch starts per frame
    output logic [7:0]  dbg_fetch_done_o,      // Line fetch completions per frame
    output logic [7:0]  dbg_read_blocked_o,    // FETCH_READ cycles blocked by port unavailable
    output logic [7:0]  dbg_yield_busy_o,      // FETCH_READ cycles yielding to near-full write FIFO
    output logic [7:0]  dbg_late_line_o,       // Behind-display late-line detections per frame
    output logic [7:0]  dbg_flags_o,           // Live status flags
    output logic [7:0]  dbg_line_not_ready_o,  // Display line-starts before line fully fetched
    output logic [7:0]  dbg_line_lag_max_o,    // Max display-vs-fetched line lag per frame
    output logic [7:0]  dbg_ready_phase_err_o, // Read ready pulses outside FETCH_WAIT
    output logic [7:0]  dbg_vsync_raw_o,       // Raw fb_vsync pulses seen in this frame
    output logic [7:0]  dbg_frame_start_accept_o, // Accepted frame starts in this frame
    output logic [7:0]  dbg_frame_start_reject_o  // Rejected fb_vsync pulses in this frame
);

    // =========================================================================
    // 480p display parameters
    // =========================================================================

    localparam HDMI_WIDTH  = 720;
    localparam HDMI_HEIGHT = 480;

    // =========================================================================
    // Color conversion functions
    // =========================================================================

    // RGB666 (18-bit) to RGB565 (16-bit) for SDRAM storage
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

    // Test pattern: configurable vertical bars
    // TEST_PATTERN==3: 8-pixel wide bars (same-color pairs only)
    // TEST_PATTERN==4: 1-pixel alternating stripes (EVERY pair has mixed colors)
    //   Tests whether the pixel packer/SDRAM handles mixed-color pairs correctly.
    function automatic [COLOR_BITS-1:0] test_pixel(input [9:0] x);
        case (x[5:3])
            3'd0: test_pixel = 18'h3FFFF;  // white
            3'd1: test_pixel = 18'h3F000;  // red
            3'd2: test_pixel = 18'h00FC0;  // green
            3'd3: test_pixel = 18'h0003F;  // blue
            3'd4: test_pixel = 18'h00FFF;  // cyan
            3'd5: test_pixel = 18'h3F03F;  // magenta
            3'd6: test_pixel = 18'h3FFC0;  // yellow
            3'd7: test_pixel = 18'h00000;  // black
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    // Write FIFO — buffers packed pixel pairs for SDRAM
    // =========================================================================
    //
    // Each entry: {21-bit addr, 32-bit data} = 53 bits
    // Depth 256 absorbs full write bursts during uninterrupted line fetches.
    // The fetcher only yields to writes as a safety valve when the FIFO is
    // near full, allowing line fetches to complete as fast as possible.

    localparam FIFO_DEPTH = 256;
    localparam FIFO_ADDR_BITS = 8;  // log2(256)
    // Yield reads only as a safety valve when write FIFO backs up.
    localparam FIFO_YIELD_THRESHOLD = 64;

    reg [52:0] wr_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_ADDR_BITS:0] fifo_wr_ptr_r, fifo_rd_ptr_r;

    wire [FIFO_ADDR_BITS:0] fifo_count_w = fifo_wr_ptr_r - fifo_rd_ptr_r;
    wire fifo_empty_w = (fifo_wr_ptr_r == fifo_rd_ptr_r);
    wire fifo_full_w  = fifo_count_w[FIFO_ADDR_BITS];  // MSB set when count >= 256
    // Start yielding reads earlier so write FIFO never reaches drop-on-full behavior.
    wire fifo_busy_w  = (fifo_count_w >= FIFO_YIELD_THRESHOLD);
    wire [7:0] fifo_count_clamped_w = fifo_count_w[FIFO_ADDR_BITS] ? 8'hFF : fifo_count_w[7:0];

    // =========================================================================
    // Write path — pixel packing + FIFO (clk domain, 54 MHz)
    // =========================================================================
    //
    // Accepts RGB666 pixels from renderers, converts to RGB565, buffers even
    // pixels, packs pairs into 32-bit words, and pushes to FIFO for SDRAM.
    // SDRAM address uses packed width (fb_width/2 words per line).

    reg [10:0] wr_x_r;
    reg [9:0]  wr_y_r;
    reg [10:0] wr_width_r;           // latched at vsync
    reg [20:0] wr_line_base_r;       // y * (fb_width/2)
    reg [15:0] wr_pixel_even_r;      // buffered even pixel (RGB565)
    reg        frame_pending_r;      // waiting for first fb_we after accepted frame start
    reg        frame_parity_r;      // toggles each frame for TEST_PATTERN==6
    // Reject implausibly short frame-start intervals so a spurious fb_vsync
    // pulse cannot reset write/read tracking mid-frame.
    localparam [19:0] FRAME_MIN_CYCLES = 20'd540000;  // ~10ms at 54MHz
    reg [19:0] frame_gap_r;
    wire frame_start_w = fb_vsync_r && (frame_gap_r >= FRAME_MIN_CYCLES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    // 3/4/6 test the full round-trip: RGB666→RGB565 → FIFO → SDRAM → fetch → RGB565→RGB666 → BRAM → display
    wire [COLOR_BITS-1:0] wr_pixel_data_w = (TEST_PATTERN == 6) ? test_pixel_frame_alt(frame_parity_r) :
                                             (TEST_PATTERN == 4) ? test_pixel_mixed(wr_x_r[9:0]) :
                                             (TEST_PATTERN == 3) ? test_pixel(wr_x_r[9:0]) : fb_data_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_x_r <= 11'd0;
            wr_y_r <= 10'd0;
            wr_width_r <= 11'd560;
            wr_line_base_r <= 21'd0;
            fifo_wr_ptr_r <= '0;
            wr_pixel_even_r <= 16'd0;
            frame_pending_r <= 1'b0;
            frame_parity_r <= 1'b0;
        end else begin
            if (frame_start_w) begin
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
                end else begin
                    if (wr_x_r[0] == 1'b0) begin
                        // Even pixel — buffer as RGB565
                        wr_pixel_even_r <= rgb666_to_565(wr_pixel_data_w);
                    end else if (!fifo_full_w) begin
                        // Odd pixel — pack with buffered even and push to FIFO
                        wr_fifo[fifo_wr_ptr_r[FIFO_ADDR_BITS-1:0]] <= {
                            wr_line_base_r + {11'd0, wr_x_r[10:1]},  // packed addr
                            rgb666_to_565(wr_pixel_data_w),            // odd pixel [31:16]
                            wr_pixel_even_r                            // even pixel [15:0]
                        };
                        fifo_wr_ptr_r <= fifo_wr_ptr_r + 1;
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

    // FIFO drain to SDRAM write port
    wire [52:0] fifo_head_w = wr_fifo[fifo_rd_ptr_r[FIFO_ADDR_BITS-1:0]];
    wire fifo_pop_w = !fifo_empty_w && fb_write_port.available;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fifo_rd_ptr_r <= '0;
        else if (fifo_pop_w)
            fifo_rd_ptr_r <= fifo_rd_ptr_r + 1;
    end

    assign fb_write_port.addr    = fifo_head_w[52:32];
    assign fb_write_port.data    = fifo_head_w[31:0];
    assign fb_write_port.byte_en = 4'b1111;
    assign fb_write_port.wr      = fifo_pop_w;
    assign fb_write_port.rd      = 1'b0;
    assign fb_write_port.burst   = 1'b0;

    // =========================================================================
    // CDC: HDMI cy → clk domain (gray-code)
    // =========================================================================

    function automatic [9:0] bin2gray(input [9:0] b);
        return b ^ (b >> 1);
    endfunction

    function automatic [9:0] gray2bin(input [9:0] g);
        reg [9:0] b;
        b[9] = g[9];
        for (int i = 8; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    reg [9:0] cy_gray_px_r;
    always @(posedge clk_pixel) begin
        cy_gray_px_r <= bin2gray(hdmi_cy);
    end

    reg [9:0] cy_gray_sync1_r, cy_gray_sync2_r;
    reg [9:0] cy_sync_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cy_gray_sync1_r <= 10'd0;
            cy_gray_sync2_r <= 10'd0;
            cy_sync_r <= 10'd0;
        end else begin
            cy_gray_sync1_r <= cy_gray_px_r;
            cy_gray_sync2_r <= cy_gray_sync1_r;
            cy_sync_r <= gray2bin(cy_gray_sync2_r);
        end
    end

    // =========================================================================
    // Read path / Line Fetch FSM — clk domain (54 MHz)
    // =========================================================================
    //
    // Reactive fetch: continuously checks whether a new line needs fetching
    // based on the CDC'd display position (cy_sync_r). No counter, no frame
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
    reg [10:0] h_border_r;
    reg [9:0]  v_border_r;
    reg [8:0]  fb_height_r;
    always @(posedge clk) begin
        h_border_r <= (HDMI_WIDTH - fb_width) >> 1;
        v_border_r <= (HDMI_HEIGHT - {fb_height, 1'b0}) >> 1;
        fb_height_r <= fb_height[8:0];
    end

    // Packed width: SDRAM words per line (fb_width / 2), registered to break
    // timing path from use_vgc_r→fb_width mux (only changes at vsync)
    reg [10:0] packed_width_r;
    always @(posedge clk) begin
        packed_width_r <= {1'b0, fb_width[10:1]};
    end
    localparam integer FB_READ_BURST_WORDS = 2;  // Must match SDRAM controller's READ_BURST_WORDS
    localparam integer PREFETCH_LEAD_LINES = 12;

    localparam FETCH_IDLE    = 2'd0;
    localparam FETCH_READ    = 2'd1;
    localparam FETCH_WAIT    = 2'd2;
    localparam FETCH_GAP     = 2'd3;  // 1-cycle gap between bursts for port fairness

    reg [1:0]  fetch_state_r;
    reg [8:0]  last_fetched_line_r;  // 9'h1FF = invalid sentinel
    reg [10:0] fetch_word_r;
    reg [20:0] fetch_addr_r;
    reg [20:0] fetch_line_base_r;   // Base SDRAM addr of current/last fetched line
    reg        fetch_bank_r;
    reg [3:0]  fetch_beats_left_r;

    // Debug counters (saturating, reset each frame at fb_vsync)
    reg [7:0] dbg_fifo_highwater_r;
    reg [7:0] dbg_fifo_overflow_r;
    reg [7:0] dbg_fetch_start_r;
    reg [7:0] dbg_fetch_done_r;
    reg [7:0] dbg_read_blocked_r;
    reg [7:0] dbg_yield_busy_r;
    reg [7:0] dbg_late_line_r;
    reg       late_line_prev_r;
    reg [7:0] dbg_line_not_ready_r;
    reg [7:0] dbg_line_lag_max_r;
    reg [7:0] dbg_ready_phase_err_r;
    reg [7:0] dbg_vsync_raw_r;
    reg [7:0] dbg_frame_start_accept_r;
    reg [7:0] dbg_frame_start_reject_r;
    reg [8:0] completed_line_even_r;
    reg [8:0] completed_line_odd_r;
    reg [8:0] display_line_prev_r;
    reg       display_active_prev_r;

    // Display position in clk domain (from CDC'd cy)
    wire [9:0] cy_minus_border_w = cy_sync_r - v_border_r;
    wire [8:0] display_fb_line_w = cy_minus_border_w[9:1];
    wire       display_in_active_w = (cy_sync_r >= v_border_r) &&
                                      (cy_sync_r < v_border_r + {fb_height_r, 1'b0});

    // Approaching active area: prefetch line 0 early in vblank so first active
    // lines are guaranteed ready.
    wire [10:0] cy_prefetch_sum_w = {1'b0, cy_sync_r} + 11'(PREFETCH_LEAD_LINES);
    wire cy_approaching_active_w = (cy_sync_r < v_border_r) &&
                                    (cy_prefetch_sum_w >= {1'b0, v_border_r});

    wire [8:0] next_line_w = display_fb_line_w + 9'd1;
    wire [10:0] fetch_words_left_w = packed_width_r - fetch_word_r;
    wire fetch_use_burst_w = (fetch_words_left_w >= FB_READ_BURST_WORDS[10:0]);
    wire wr_drop_w = fb_we_r && wr_x_r[0] && fifo_full_w;
    wire [8:0] completed_line_for_display_w = display_fb_line_w[0] ? completed_line_odd_r : completed_line_even_r;
    wire line_ready_w = (completed_line_for_display_w == display_fb_line_w);
    wire [8:0] line_lag_w = (completed_line_for_display_w == 9'h1FF ||
                             completed_line_for_display_w >= display_fb_line_w) ?
                             9'd0 : (display_fb_line_w - completed_line_for_display_w);
    wire [7:0] line_lag_clamped_w = line_lag_w[8] ? 8'hFF : line_lag_w[7:0];
    wire display_line_step_w = display_in_active_w &&
                               (!display_active_prev_r || (display_fb_line_w != display_line_prev_r));
    wire ready_phase_err_w = fb_read_port.ready && (fetch_state_r != FETCH_WAIT);
    wire late_line_w = display_in_active_w &&
                       (display_fb_line_w != 9'd0) &&
                       (last_fetched_line_r != 9'h1FF) &&
                       (last_fetched_line_r < display_fb_line_w);
    wire fetch_start_line0_w = (fetch_state_r == FETCH_IDLE) &&
                               cy_approaching_active_w &&
                               (last_fetched_line_r != 9'd0) &&
                               px_empty;
    wire fetch_start_next_w = (fetch_state_r == FETCH_IDLE) &&
                              !fetch_start_line0_w &&
                              display_in_active_w &&
                              (next_line_w < fb_height_r) &&
                              (next_line_w != last_fetched_line_r) &&
                              px_empty;
    wire fetch_start_pulse_w = fetch_start_line0_w || fetch_start_next_w;
    wire fetch_done_pulse_w = (fetch_state_r == FETCH_WAIT) &&
                              fb_read_port.ready &&
                              (fetch_word_r == packed_width_r - 11'd1);

    // Per-frame debug counters and live high-water tracking
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_fifo_highwater_r <= 8'd0;
            dbg_fifo_overflow_r <= 8'd0;
            dbg_fetch_start_r <= 8'd0;
            dbg_fetch_done_r <= 8'd0;
            dbg_read_blocked_r <= 8'd0;
            dbg_yield_busy_r <= 8'd0;
            dbg_late_line_r <= 8'd0;
            late_line_prev_r <= 1'b0;
            dbg_line_not_ready_r <= 8'd0;
            dbg_line_lag_max_r <= 8'd0;
            dbg_ready_phase_err_r <= 8'd0;
            dbg_vsync_raw_r <= 8'd0;
            dbg_frame_start_accept_r <= 8'd0;
            dbg_frame_start_reject_r <= 8'd0;
            completed_line_even_r <= 9'h1FF;
            completed_line_odd_r <= 9'h1FF;
            display_line_prev_r <= 9'd0;
            display_active_prev_r <= 1'b0;
        end else if (frame_start_w) begin
            dbg_fifo_highwater_r <= fifo_count_clamped_w;
            dbg_fifo_overflow_r <= 8'd0;
            dbg_fetch_start_r <= 8'd0;
            dbg_fetch_done_r <= 8'd0;
            dbg_read_blocked_r <= 8'd0;
            dbg_yield_busy_r <= 8'd0;
            dbg_late_line_r <= 8'd0;
            late_line_prev_r <= 1'b0;
            dbg_line_not_ready_r <= 8'd0;
            dbg_line_lag_max_r <= 8'd0;
            dbg_ready_phase_err_r <= 8'd0;
            dbg_vsync_raw_r <= 8'd1;
            dbg_frame_start_accept_r <= 8'd1;
            dbg_frame_start_reject_r <= 8'd0;
            completed_line_even_r <= 9'h1FF;
            completed_line_odd_r <= 9'h1FF;
            display_line_prev_r <= 9'd0;
            display_active_prev_r <= 1'b0;
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

            if (fetch_start_pulse_w && dbg_fetch_start_r != 8'hFF)
                dbg_fetch_start_r <= dbg_fetch_start_r + 8'd1;

            if (fetch_done_pulse_w && dbg_fetch_done_r != 8'hFF)
                dbg_fetch_done_r <= dbg_fetch_done_r + 8'd1;

            if ((fetch_state_r == FETCH_READ) && fifo_busy_w && dbg_yield_busy_r != 8'hFF)
                dbg_yield_busy_r <= dbg_yield_busy_r + 8'd1;

            if ((fetch_state_r == FETCH_READ) && !fifo_busy_w &&
                !fb_read_port.available && dbg_read_blocked_r != 8'hFF)
                dbg_read_blocked_r <= dbg_read_blocked_r + 8'd1;

            if (late_line_w && !late_line_prev_r && dbg_late_line_r != 8'hFF)
                dbg_late_line_r <= dbg_late_line_r + 8'd1;

            late_line_prev_r <= late_line_w;

            if (fetch_done_pulse_w) begin
                if (last_fetched_line_r[0])
                    completed_line_odd_r <= last_fetched_line_r;
                else
                    completed_line_even_r <= last_fetched_line_r;
            end

            if (display_line_step_w && !line_ready_w && dbg_line_not_ready_r != 8'hFF)
                dbg_line_not_ready_r <= dbg_line_not_ready_r + 8'd1;

            if (display_in_active_w && (line_lag_clamped_w > dbg_line_lag_max_r))
                dbg_line_lag_max_r <= line_lag_clamped_w;

            if (ready_phase_err_w && dbg_ready_phase_err_r != 8'hFF)
                dbg_ready_phase_err_r <= dbg_ready_phase_err_r + 8'd1;

            if (display_in_active_w)
                display_line_prev_r <= display_fb_line_w;
            display_active_prev_r <= display_in_active_w;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_state_r <= FETCH_IDLE;
            last_fetched_line_r <= 9'h1FF;
            fetch_word_r <= 11'd0;
            fetch_addr_r <= 21'd0;
            fetch_line_base_r <= 21'd0;
            fetch_bank_r <= 1'b0;
            fetch_beats_left_r <= 4'd0;
        end else begin
            case (fetch_state_r)

            FETCH_IDLE: begin
                // Check every cycle — no cy_changed gate needed.
                // last_fetched_line_r prevents redundant fetches.
                if (cy_approaching_active_w && last_fetched_line_r != 9'd0) begin
                    // Approaching active area — prefetch line 0
                    last_fetched_line_r <= 9'd0;
                    fetch_bank_r <= 1'b0;
                    fetch_word_r <= 11'd0;
                    fetch_beats_left_r <= 4'd0;
                    fetch_line_base_r <= 21'd0;
                    fetch_addr_r <= 21'd0;
                    fetch_state_r <= FETCH_READ;
                end else if (display_in_active_w &&
                             next_line_w < fb_height_r &&
                             next_line_w != last_fetched_line_r) begin
                    // Displaying line N — prefetch line N+1
                    // Use incremental addition instead of multiplication
                    // (packed_width_r only changes at vsync so this is always correct)
                    last_fetched_line_r <= next_line_w;
                    fetch_bank_r <= next_line_w[0];
                    fetch_word_r <= 11'd0;
                    fetch_beats_left_r <= 4'd0;
                    fetch_line_base_r <= fetch_line_base_r + {10'd0, packed_width_r};
                    fetch_addr_r <= fetch_line_base_r + {10'd0, packed_width_r};
                    fetch_state_r <= FETCH_READ;
                end
            end

            FETCH_READ: begin
                // SDRAM runs at 108 MHz via CDC (~49% utilization), no available
                // gate needed — port 0 hardware priority keeps DOC latency well
                // within budget. Only yield if write FIFO is near full.
                if (!fifo_busy_w) begin
                    fetch_beats_left_r <= fetch_use_burst_w ? 4'(FB_READ_BURST_WORDS) : 4'd1;
                    fetch_state_r <= FETCH_WAIT;
                end
            end

            FETCH_WAIT: begin
                if (fb_read_port.ready) begin
                    if (fetch_word_r == packed_width_r - 11'd1) begin
                        fetch_state_r <= FETCH_IDLE;
                    end else begin
                        fetch_word_r <= fetch_word_r + 11'd1;
                        fetch_addr_r <= fetch_addr_r + 21'd1;
                        fetch_beats_left_r <= fetch_beats_left_r - 4'd1;
                        // Go through FETCH_GAP between bursts so lower-priority
                        // ports (DOC, FB_WRITE) get a window to be serviced.
                        fetch_state_r <= (fetch_beats_left_r == 4'd1) ? FETCH_GAP : FETCH_WAIT;
                    end
                end
            end

            FETCH_GAP: begin
                // 1-cycle gap: port 0 has no queued request, SDRAM can
                // service DOC or FB_WRITE if they have pending requests.
                fetch_state_r <= FETCH_READ;
            end

            default: fetch_state_r <= FETCH_IDLE;
            endcase
        end
    end

    // Drive read port — SDRAM runs at 108 MHz via CDC, ample bandwidth headroom
    assign fb_read_port.addr    = fetch_addr_r;
    assign fb_read_port.data    = 32'd0;
    assign fb_read_port.byte_en = 4'b1111;
    assign fb_read_port.wr      = 1'b0;
    assign fb_read_port.rd      = (fetch_state_r == FETCH_READ) && !fifo_busy_w;
    assign fb_read_port.burst   = fetch_use_burst_w;

    assign dbg_fifo_level_o = fifo_count_clamped_w;
    assign dbg_fifo_highwater_o = dbg_fifo_highwater_r;
    assign dbg_fifo_overflow_o = dbg_fifo_overflow_r;
    assign dbg_fetch_start_o = dbg_fetch_start_r;
    assign dbg_fetch_done_o = dbg_fetch_done_r;
    assign dbg_read_blocked_o = dbg_read_blocked_r;
    assign dbg_yield_busy_o = dbg_yield_busy_r;
    assign dbg_late_line_o = dbg_late_line_r;
    assign dbg_line_not_ready_o = dbg_line_not_ready_r;
    assign dbg_line_lag_max_o = dbg_line_lag_max_r;
    assign dbg_ready_phase_err_o = dbg_ready_phase_err_r;
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
    // Single BRAM array: 2 banks x 1024 entries x 18 bits (RGB666).
    // Write port: clk (54 MHz) — serialized SDRAM read responses
    // Read port: clk_pixel (27 MHz) — HDMI pixel output
    //
    // Previous experiments (EXP 1-3) showed that the even/odd pixel mux
    // between two separate BRAMs causes ghosting artifacts regardless of
    // pipeline depth or register placement. This approach eliminates the
    // mux entirely by storing 1 pixel per entry (like the working DDR3
    // framebuffer), serializing the 2-pixel SDRAM words through a small
    // buffer on the write side.

    reg [COLOR_BITS-1:0] line_buf [0:2047] /* synthesis syn_ramstyle="block_ram" */;

    // ---- Write side (clk domain, 54 MHz) ----
    // Each 32-bit SDRAM word contains 2 packed RGB565 pixels.
    // SDRAM ready can pulse on consecutive cycles during burst reads,
    // so we buffer pixels and drain 1 per cycle to the single-port BRAM.

    wire lb_wr_w = fb_read_port.ready && (fetch_state_r == FETCH_WAIT);

    // ---- Read FIFO: buffer raw 32-bit SDRAM words (single write port) ----
    // Replaces the 4-entry px_buf that used simultaneous 2-write push.
    // Gowin distributed RAM has a single write port; the old dual-write pattern
    // forced register duplication and caused pixel data corruption (ghosting).
    localparam RD_FIFO_DEPTH = 8;
    localparam RD_FIFO_ADDR_BITS = 3;
    reg [31:0] rd_fifo [0:RD_FIFO_DEPTH-1];
    reg [RD_FIFO_ADDR_BITS:0] rd_fifo_wr_ptr, rd_fifo_rd_ptr;
    wire [RD_FIFO_ADDR_BITS:0] rd_fifo_count = rd_fifo_wr_ptr - rd_fifo_rd_ptr;
    wire rd_fifo_empty = (rd_fifo_wr_ptr == rd_fifo_rd_ptr);

    // Response handler: pop 32-bit words and write 2 pixels sequentially.
    // Matches the DDR3 framebuffer's rd_pixel_active / rd_pixel_idx pattern.
    reg [31:0] rd_word_latched_r;
    reg        rd_pixel_idx_r;      // 0 = even pixel [15:0], 1 = odd pixel [31:16]
    reg        rd_pixel_active_r;
    wire rd_fifo_push = lb_wr_w && !rd_fifo_count[RD_FIFO_ADDR_BITS];
    wire px_empty = rd_fifo_empty && !rd_pixel_active_r;
    reg [10:0] lb_wr_pixel_x;

    // Push 1 word per SDRAM ready pulse (single write port — no multi-write)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
                (TEST_PATTERN == 1) ? test_pixel(lb_wr_pixel_x[9:0]) :
                rd_pixel_idx_r ? rgb565_to_666(rd_word_latched_r[31:16]) :
                                 rgb565_to_666(rd_word_latched_r[15:0]);
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

    // TEST_PATTERN==5: SDRAM bypass — write fb_data directly to line buffer.
    // Bypasses FIFO, SDRAM, px_buf entirely. Tests line buffer + display pipeline
    // in isolation from the SDRAM round-trip.
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

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                bypass_x_r <= 11'd0;
                bypass_y_r <= 9'd0;
                bp_sync_pending_r <= 1'b0;
            end else begin
                // Mark frame sync pending on scan_timer vsync
                if (frame_start_w)
                    bp_sync_pending_r <= 1'b1;

                if (fb_we_r) begin
                    line_buf[{bypass_y_r[0], bypass_x_r[9:0]}] <= fb_data_r;
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
    // Bank = line parity, computed directly from hdmi_cy — no CDC needed.
    wire [9:0] display_cy_offset_px_w = hdmi_cy - v_border_px_r;
    wire       rd_bank_w = display_cy_offset_px_w[1];

    // =========================================================================
    // Output path — clk_pixel domain (27 MHz)
    // =========================================================================

    reg [10:0] fb_width_px_r;
    reg [9:0]  fb_height_px_r;
    reg [10:0] h_border_px_r;
    reg [9:0]  v_border_px_r;

    always @(posedge clk_pixel) begin
        fb_width_px_r <= fb_width;
        fb_height_px_r <= fb_height;
        h_border_px_r <= (HDMI_WIDTH - fb_width) >> 1;
        v_border_px_r <= (HDMI_HEIGHT - {fb_height, 1'b0}) >> 1;
    end

    wire in_v_active_px_w = (hdmi_cy >= v_border_px_r) &&
                             (hdmi_cy < v_border_px_r + {fb_height_px_r, 1'b0});

    // EXP 20: Explicit BSRAM read register + pipeline alignment.
    //
    // The line buffer is inferred as BSRAM (syn_ramstyle="block_ram"), which has
    // synchronous reads — but the original code used a wire assignment
    // (line_buf[addr]) that implies async read. This mismatch causes:
    //   1) Ambiguous read-port clock selection by the synthesizer
    //   2) Unconstrained timing path from address to data
    //   3) in_active_px_r / scanline_dim_r 1 cycle ahead of pixel data
    //
    // Fix: explicitly register the BSRAM read output on clk_pixel, and delay
    // the control signals to match.

    wire [10:0] next_cx_w = hdmi_cx + 11'd3;
    wire        next_in_h_active_w = (next_cx_w >= {1'b0, h_border_px_r}) &&
                                      (next_cx_w < {1'b0, h_border_px_r} + fb_width_px_r);
    wire [9:0]  next_fb_x_w = next_cx_w[9:0] - h_border_px_r[9:0];

    // Pipeline stage 1: address register + control flags (posedge N)
    reg [10:0] lb_rd_addr;
    reg in_active_s1_r;
    reg scanline_dim_s1_r;

    always @(posedge clk_pixel) begin
        if (next_in_h_active_w && in_v_active_px_w)
            lb_rd_addr <= {rd_bank_w, next_fb_x_w[9:0]};
        else
            lb_rd_addr <= 11'd0;
        in_active_s1_r <= next_in_h_active_w && in_v_active_px_w;
        scanline_dim_s1_r <= scanline_en && hdmi_cy[0];
    end

    // Pipeline stage 2: BSRAM read register + delayed control (posedge N+1)
    // This gives the synthesizer a clear clk_pixel read clock for the BSRAM
    // and ensures deterministic 1-cycle read latency.
    reg [COLOR_BITS-1:0] lb_rd_data_r;
    reg in_active_px_r;
    reg scanline_dim_r;

    always @(posedge clk_pixel) begin
        lb_rd_data_r <= (TEST_PATTERN == 2) ?
            test_pixel(lb_rd_addr[9:0]) : line_buf[lb_rd_addr];
        in_active_px_r <= in_active_s1_r;
        scanline_dim_r <= scanline_dim_s1_r;
    end

    // EXP 22: Binary threshold — non-zero pixel data → white, zero → black.
    // This makes ghost pixels maximally visible by eliminating color ambiguity.
    wire [23:0] active_rgb_w = (THRESHOLD_DIAG != 0) ?
        (lb_rd_data_r != {COLOR_BITS{1'b0}} ? 24'hFFFFFF : 24'h000000) :
        torgb(lb_rd_data_r);
    wire [23:0] border_rgb_w = torgb(rgb565_to_666(rgb666_to_565(border_color)));

    wire [23:0] pixel_rgb_w = in_active_px_r ? active_rgb_w : border_rgb_w;

    wire [23:0] dimmed_rgb_w = {1'b0, pixel_rgb_w[23:17],
                                 1'b0, pixel_rgb_w[15:9],
                                 1'b0, pixel_rgb_w[7:1]};

    wire [23:0] final_rgb_w = sleep_i ? 24'd0 :
                               scanline_dim_r ? dimmed_rgb_w : pixel_rgb_w;

    assign r_o = final_rgb_w[23:16];
    assign g_o = final_rgb_w[15:8];
    assign b_o = final_rgb_w[7:0];

endmodule
