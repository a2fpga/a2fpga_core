// Scan Timer — Apple II scanline counter synchronized to bus timing
//
// (c) 2023,2024,2025 Ed Anuff <ed@a2fpga.com>
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
// Generates scanline and pixel counters from Apple II bus timing.
// Each extended_cycle pulse from the bus corresponds to one horizontal
// scanline boundary (the "long cycle" in Apple II timing).
//
// The scanline counter uses a 0-261 range (262 NTSC lines) where:
//   - Lines 0-191: visible display (scan lines 0-191)
//   - Lines 192-261: vertical blanking (70 lines)
//
// On reset, the counter initializes to 256 (not 0) to match the real
// Mega II hardware, which starts its 9-bit counter at $0FA after reset.
// The Mega II counts $0FA-$0FF (6 VBL lines) before reaching $100
// (scan line 0). Our reset value of 256 maps to this: after 6
// extended_cycle pulses (256->261->wrap), we reach 0 = scan line 0,
// synchronized with the real hardware.
//
// See: Apple IIgs Technical Note #39 — Mega II Video Counters
//
// Optional bus-snooped resync:
//   VGC_VERTCNT_LOCK: snoop $C02E reads to correct drift vs. hardware
//   VGC_VBL_LOCK: snoop $C019 reads to correct drift at VBL boundaries
//   RESYNC_THRESHOLD: minimum scanline delta before correction applied
//   VBL polarity auto-detected at runtime via a2bus_if.sw_gs (IIgs vs IIe)
//
// See: boards/a2mega/docs/scan_timer_design.md for detailed design rationale.
//

module scan_timer #(
    parameter VGC_VERTCNT_LOCK = 0,   // 1 = snoop $C02E reads for resync
    parameter VGC_VBL_LOCK = 0,       // 1 = snoop $C019 reads for resync
    parameter RESYNC_THRESHOLD = 2    // min scanline delta to trigger correction
) (
    a2bus_if.slave a2bus_if,
    output [8:0] scanline_o,
    output hsync_o,
    output vsync_o,
    output [9:0] pixel_o,

    // Debug outputs for DebugOverlay
    output [8:0] dbg_last_delta_o,      // last resync abs_delta value
    output [8:0] dbg_last_expected_o,   // last resync expected scanline
    output [8:0] dbg_last_actual_o,     // our scanline counter at resync moment
    output [7:0] dbg_last_raw_data_o,   // last raw register byte seen
    output [7:0] dbg_vbl_correct_o,     // number of VBL corrections applied
    output [7:0] dbg_vertcnt_correct_o, // number of VERTCNT corrections applied
    output [7:0] dbg_c02e_count_o,      // number of $C02E reads seen (wraps at 255)
    output [7:0] dbg_c019_count_o       // number of $C019 reads seen (wraps at 255)
);

    // =========================================================================
    // Constants
    // =========================================================================

    localparam LINES_PER_FRAME = 262;
    localparam LAST_LINE       = LINES_PER_FRAME - 1;  // 261
    localparam VBL_START_LINE  = 192;
    localparam RESET_LINE      = 256;  // Mega II starts at $0FA = 6 lines before visible

    // =========================================================================
    // Core counters
    // =========================================================================

    reg [8:0] scanline_counter_r;
    reg vsync_r;
    reg hsync_r;
    reg [9:0] pixel_counter_r;

    // =========================================================================
    // Debug registers — latched on resync events for overlay display
    // =========================================================================

    reg [8:0] dbg_last_delta_r;
    reg [8:0] dbg_last_expected_r;
    reg [8:0] dbg_last_actual_r;
    reg [7:0] dbg_last_raw_data_r;
    reg [7:0] dbg_vbl_correct_r;
    reg [7:0] dbg_vertcnt_correct_r;

    // =========================================================================
    // Bus snoop signals
    // =========================================================================

    wire read_strobe_w = a2bus_if.rw_n && a2bus_if.data_in_strobe;

    // =========================================================================
    // Bus read counters — always active, independent of LOCK parameters
    // =========================================================================

    wire c02e_read_w = read_strobe_w && (a2bus_if.addr == 16'hC02E) && !a2bus_if.m2sel_n;
    wire c019_read_w = read_strobe_w && (a2bus_if.addr == 16'hC019) && !a2bus_if.m2sel_n;

    reg [7:0] dbg_c02e_count_r;
    reg [7:0] dbg_c019_count_r;

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            dbg_c02e_count_r <= 8'd0;
            dbg_c019_count_r <= 8'd0;
        end else begin
            if (c02e_read_w) dbg_c02e_count_r <= dbg_c02e_count_r + 1'b1;
            if (c019_read_w) dbg_c019_count_r <= dbg_c019_count_r + 1'b1;
        end
    end

    // =========================================================================
    // Resync interface — driven by generate blocks below
    // =========================================================================

    wire vertcnt_resync_w;
    wire [8:0] vertcnt_expected_w;
    wire [7:0] vertcnt_raw_data_w;
    wire vbl_resync_w;
    wire [8:0] vbl_expected_w;
    wire [7:0] vbl_raw_data_w;

    // =========================================================================
    // VGC_VERTCNT_LOCK — snoop $C02E reads for precise scanline resync
    // =========================================================================
    //
    // $C02E contains {V5,V4,V3,V2,V1,V0,VC,VB} — the top 8 bits of the
    // Mega II's 9-bit vertical counter. The 9th bit (VA) is in $C02F[7].
    //
    // Since we only snoop $C02E, we have 2-scanline precision. We reconstruct
    // the approximate scanline and correct if the delta exceeds threshold.
    //
    // Conversion: nine_bit_approx = {vertcnt_byte, 1'b0}
    //   If nine_bit_approx >= 256: expected_line = nine_bit_approx - 256
    //   If nine_bit_approx <  256: expected_line = nine_bit_approx - 256 + 262
    //                             (i.e. nine_bit_approx + 6)

    generate if (VGC_VERTCNT_LOCK) begin : gen_vertcnt_lock

        wire vertcnt_read_w = read_strobe_w &&
                              (a2bus_if.addr == 16'hC02E) &&
                              !a2bus_if.m2sel_n;

        reg vertcnt_read_r;
        reg [7:0] vertcnt_data_r;
        reg vertcnt_resync_r;
        reg [8:0] vertcnt_expected_r;

        always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
            if (!a2bus_if.system_reset_n) begin
                vertcnt_read_r <= 1'b0;
                vertcnt_data_r <= 8'd0;
                vertcnt_resync_r <= 1'b0;
                vertcnt_expected_r <= 9'd0;
            end else begin
                vertcnt_resync_r <= 1'b0;

                if (vertcnt_read_w) begin
                    vertcnt_read_r <= 1'b1;
                    vertcnt_data_r <= a2bus_if.data;
                end else if (vertcnt_read_r) begin
                    // Process captured VertCnt one cycle after capture
                    vertcnt_read_r <= 1'b0;

                    // Reconstruct approximate scanline from VertCnt byte
                    // nine_bit_approx = {vertcnt_data_r, 1'b0} (VA assumed 0)
                    // Convert from Mega II $FA-based to our 0-based:
                    //   Mega II $100 (=256) = our line 0
                    //   Values >= $80 ($100-$1FF with VA=0): our_line = nine_bit - 256
                    //   Values <  $80 ($0FA-$0FF with VA=0): our_line = nine_bit + 6
                    if (vertcnt_data_r >= 8'h80) begin
                        // nine_bit = {vertcnt_data_r, 1'b0} >= 256
                        // expected = nine_bit - 256 = {0, vertcnt_data_r[6:0], 1'b0}
                        vertcnt_expected_r <= {1'b0, vertcnt_data_r[6:0], 1'b0};
                    end else begin
                        // nine_bit = {vertcnt_data_r, 1'b0} < 256
                        // expected = nine_bit + 6
                        vertcnt_expected_r <= {vertcnt_data_r, 1'b0} + 9'd6;
                    end
                    vertcnt_resync_r <= 1'b1;
                end
            end
        end

        assign vertcnt_resync_w = vertcnt_resync_r;
        assign vertcnt_expected_w = vertcnt_expected_r;
        assign vertcnt_raw_data_w = vertcnt_data_r;

    end else begin : gen_no_vertcnt_lock

        assign vertcnt_resync_w = 1'b0;
        assign vertcnt_expected_w = 9'd0;
        assign vertcnt_raw_data_w = 8'd0;

    end endgenerate

    // =========================================================================
    // VGC_VBL_LOCK — snoop $C019 reads for VBL-edge resync
    // =========================================================================
    //
    // On the Apple IIgs, $C019 bit 7:
    //   1 (high) = VBL active (beam in blanking)
    //   0 (low)  = VBL not active (beam in visible area)
    // (Inverted sense from the Apple IIe — see TN #40)
    //
    // We detect transitions of the VBL bit and snap our counter to the
    // corresponding boundary (0 or 192) if we're off by more than threshold.
    //
    // TIGHT-POLL FILTER: Only trust transitions detected during tight
    // polling loops (e.g. LDA $C019 / BPL loop). A tight loop at ~1 MHz
    // produces consecutive $C019 reads every ~8 bus cycles = ~424 clk_logic
    // cycles at 54 MHz. We require consecutive reads within TIGHT_POLL_MAX
    // clk_logic cycles to consider a transition trustworthy. Sparse single
    // checks (thousands of cycles apart) are ignored — the transition point
    // is too imprecise to be useful.

    generate if (VGC_VBL_LOCK) begin : gen_vbl_lock

        // Max clk_logic cycles between consecutive $C019 reads to qualify
        // as a tight poll loop. 600 cycles ≈ 11µs, generous margin over
        // the ~7.8µs expected for an 8-cycle 65816 loop at 1.023 MHz.
        localparam TIGHT_POLL_MAX = 10'd600;

        wire vbl_read_w = read_strobe_w &&
                          (a2bus_if.addr == 16'hC019) &&
                          !a2bus_if.m2sel_n;

        // VBL polarity depends on computer type (from sw_gs bus signal):
        //   IIgs (sw_gs=1): data[7]=1 during VBL (TN #40)
        //   IIe  (sw_gs=0): data[7]=0 during VBL (RDVBLBAR)
        // vbl_active_w is 1 when VBL is active regardless of convention
        wire vbl_active_w = a2bus_if.sw_gs ? a2bus_if.data[7] : ~a2bus_if.data[7];

        reg vbl_prev_r;             // previous VBL active state
        reg vbl_valid_r;            // have we seen at least one $C019 read?
        reg vbl_resync_r;
        reg [8:0] vbl_expected_r;
        reg [7:0] vbl_raw_data_r;   // last raw $C019 byte for debug

        // Gap timer: counts clk_logic cycles since last $C019 read
        reg [9:0] gap_timer_r;
        wire tight_poll_w = (gap_timer_r <= TIGHT_POLL_MAX);

        always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
            if (!a2bus_if.system_reset_n) begin
                vbl_prev_r <= 1'b0;
                vbl_valid_r <= 1'b0;
                vbl_resync_r <= 1'b0;
                vbl_expected_r <= 9'd0;
                vbl_raw_data_r <= 8'd0;
                gap_timer_r <= 10'h3FF;     // start saturated (not tight)
            end else begin
                vbl_resync_r <= 1'b0;

                // Increment gap timer, saturate at max
                if (gap_timer_r != 10'h3FF)
                    gap_timer_r <= gap_timer_r + 1'b1;

                if (vbl_read_w) begin
                    if (vbl_valid_r && tight_poll_w) begin
                        // Only trust transitions during tight polling
                        if (vbl_prev_r && !vbl_active_w) begin
                            // VBL -> active: scan line 0
                            vbl_resync_r <= 1'b1;
                            vbl_expected_r <= 9'd0;
                        end else if (!vbl_prev_r && vbl_active_w) begin
                            // Active -> VBL: scan line 192
                            vbl_resync_r <= 1'b1;
                            vbl_expected_r <= VBL_START_LINE;
                        end
                    end
                    vbl_prev_r <= vbl_active_w;
                    vbl_valid_r <= 1'b1;
                    vbl_raw_data_r <= a2bus_if.data;
                    gap_timer_r <= 10'd0;   // reset gap timer on each read
                end
            end
        end

        assign vbl_resync_w = vbl_resync_r;
        assign vbl_expected_w = vbl_expected_r;
        assign vbl_raw_data_w = vbl_raw_data_r;

    end else begin : gen_no_vbl_lock

        assign vbl_resync_w = 1'b0;
        assign vbl_expected_w = 9'd0;
        assign vbl_raw_data_w = 8'd0;

    end endgenerate

    // =========================================================================
    // Resync delta calculation
    // =========================================================================

    // Compute absolute distance between two scanline values on the
    // 262-line ring (0-261).  Returns 0..131.
    function automatic [8:0] abs_delta(input [8:0] a, input [8:0] b);
        reg [8:0] fwd, rev;
        // Forward distance a->b on the 262-line ring
        if (a <= b)
            fwd = b - a;
        else
            fwd = (LINES_PER_FRAME[8:0] - a) + b;  // 262 - a + b
        // Reverse is just 262 - forward
        rev = LINES_PER_FRAME[8:0] - fwd;
        // Return shorter path
        if (fwd <= rev)
            return fwd;
        else
            return rev;
    endfunction

    // =========================================================================
    // Main counter logic
    // =========================================================================

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            scanline_counter_r <= RESET_LINE;
            hsync_r <= 1'b0;
            vsync_r <= 1'b0;
            pixel_counter_r <= 10'd0;
            dbg_last_delta_r <= 9'd0;
            dbg_last_expected_r <= 9'd0;
            dbg_last_actual_r <= 9'd0;
            dbg_last_raw_data_r <= 8'd0;
            dbg_vbl_correct_r <= 8'd0;
            dbg_vertcnt_correct_r <= 8'd0;
        end else begin
            vsync_r <= 1'b0;
            hsync_r <= 1'b0;

            if (pixel_counter_r != 10'b1111111111) begin
                pixel_counter_r <= pixel_counter_r + 1'b1;
            end

            if (a2bus_if.extended_cycle) begin
                hsync_r <= 1'b1;
                pixel_counter_r <= 10'd0;
                if (scanline_counter_r == LAST_LINE) begin
                    scanline_counter_r <= 9'd0;
                    vsync_r <= 1'b1;
                end else begin
                    scanline_counter_r <= scanline_counter_r + 1'b1;
                end
            end

            // VertCnt resync — apply if delta exceeds threshold
            if (vertcnt_resync_w) begin
                // Always latch debug info on resync event
                dbg_last_delta_r <= abs_delta(scanline_counter_r, vertcnt_expected_w);
                dbg_last_expected_r <= vertcnt_expected_w;
                dbg_last_actual_r <= scanline_counter_r;
                dbg_last_raw_data_r <= vertcnt_raw_data_w;
                if (abs_delta(scanline_counter_r, vertcnt_expected_w) > RESYNC_THRESHOLD) begin
                    scanline_counter_r <= vertcnt_expected_w;
                    dbg_vertcnt_correct_r <= dbg_vertcnt_correct_r + 1'b1;
                end
            end

            // VBL resync — apply if delta exceeds threshold
            // Tight-poll filter in gen_vbl_lock ensures only trustworthy
            // transitions reach here, so no VBL-period gating needed.
            if (vbl_resync_w) begin
                // Always latch debug info on resync event
                dbg_last_delta_r <= abs_delta(scanline_counter_r, vbl_expected_w);
                dbg_last_expected_r <= vbl_expected_w;
                dbg_last_actual_r <= scanline_counter_r;
                dbg_last_raw_data_r <= vbl_raw_data_w;
                if (abs_delta(scanline_counter_r, vbl_expected_w) > RESYNC_THRESHOLD) begin
                    scanline_counter_r <= vbl_expected_w;
                    dbg_vbl_correct_r <= dbg_vbl_correct_r + 1'b1;
                end
            end
        end
    end

    assign scanline_o = scanline_counter_r;
    assign hsync_o = hsync_r;
    assign vsync_o = vsync_r;
    assign pixel_o = pixel_counter_r;

    assign dbg_last_delta_o = dbg_last_delta_r;
    assign dbg_last_expected_o = dbg_last_expected_r;
    assign dbg_last_actual_o = dbg_last_actual_r;
    assign dbg_last_raw_data_o = dbg_last_raw_data_r;
    assign dbg_vbl_correct_o = dbg_vbl_correct_r;
    assign dbg_vertcnt_correct_o = dbg_vertcnt_correct_r;
    assign dbg_c02e_count_o = dbg_c02e_count_r;
    assign dbg_c019_count_o = dbg_c019_count_r;

endmodule
