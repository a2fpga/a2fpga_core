`timescale 1ns / 1ps
//
// Direct Display — Pixel Stream to HDMI Adapter
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
// Adapter that consumes pixel_stream_if and outputs directly to HDMI,
// bypassing the framebuffer. Used for direct display testing and for
// isolating generator output from framebuffer issues.
//
// Drives pixel_clk_en from display pixel clock (as a clock enable on
// clk_logic). Generates hsync/vsync/scanline from HDMI cx/cy counters.
// Handles line doubling by rendering the same scanline on consecutive
// display lines. Shows border color when generator is not active.
//
// 480p timing (720x480 @ 59.94Hz):
//   SCREEN_WIDTH  = 720
//   SCREEN_HEIGHT = 480
//   FRAME_WIDTH   = 858
//   FRAME_HEIGHT  = 525
//
// Apple II visible window: 560x384 (192 lines x 2) centered in 720x480.
//

module direct_display #(
    parameter [9:0] SCREEN_WIDTH  = 720,
    parameter [9:0] SCREEN_HEIGHT = 480,
    parameter [9:0] FRAME_WIDTH   = 858,
    parameter [9:0] FRAME_HEIGHT  = 525,
    parameter [9:0] WINDOW_WIDTH  = 560,
    parameter [9:0] WINDOW_HEIGHT = 384,    // 192 * 2
    parameter [1:0] PIX_CLK_DIV   = 2       // pixel_clk_en every N clk_i cycles (2 = 27MHz from 54MHz)
) (
    input wire clk_i,
    input wire reset_n_i,

    // Pixel stream interface
    pixel_stream_if.consumer pixel_stream,

    // HDMI raster counters (from HDMI module, in clk_i domain or CDC'd)
    input wire [9:0] cx_i,
    input wire [9:0] cy_i,

    // Border color (RGB888)
    input wire [7:0] border_r_i,
    input wire [7:0] border_g_i,
    input wire [7:0] border_b_i,

    // Video output (to HDMI)
    output wire [7:0] video_r_o,
    output wire [7:0] video_g_o,
    output wire [7:0] video_b_o
);

    // =========================================================================
    // Display geometry
    // =========================================================================

    localparam [9:0] V_BORDER = (SCREEN_HEIGHT - WINDOW_HEIGHT) / 2;
    localparam [9:0] V_TOP    = V_BORDER;
    localparam [9:0] V_BOTTOM = V_BORDER + WINDOW_HEIGHT;

    wire in_visible_lines_w = (cy_i >= V_TOP) && (cy_i < V_BOTTOM);

    // =========================================================================
    // Scanline generation — line doubling
    // =========================================================================

    // Apple II scanline = (cy - V_TOP) / 2, gives 0-191 for 384 display lines
    wire [8:0] apple_scanline_w = {1'b0, (cy_i - V_TOP) >> 1};

    // =========================================================================
    // Timing signal generation
    // =========================================================================

    // pixel_clk_en: divide clk_i by PIX_CLK_DIV (ungated — runs always)
    reg [$clog2(PIX_CLK_DIV)-1:0] pix_div_r;
    wire pix_tick_w = (pix_div_r == 0);

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            pix_div_r <= '0;
        end else begin
            if (pix_div_r == PIX_CLK_DIV - 1)
                pix_div_r <= '0;
            else
                pix_div_r <= pix_div_r + 1;
        end
    end

    // hsync: pulse on every new display line within the visible window.
    // Fires on both even and odd lines — the generator re-renders the same
    // Apple II scanline for line doubling (scanline number repeats in pairs).
    reg [9:0] prev_cy_r;
    wire new_scanline_w = (cy_i != prev_cy_r) && in_visible_lines_w;

    always @(posedge clk_i) begin
        if (!reset_n_i)
            prev_cy_r <= 10'd0;
        else
            prev_cy_r <= cy_i;
    end

    // vsync: pulse at frame boundary
    wire vsync_pulse_w = (cy_i == FRAME_HEIGHT - 1) && (cx_i == 0);

    // =========================================================================
    // Drive pixel stream timing
    // =========================================================================

    // pixel_clk_en not gated by horizontal position — the generator gets
    // 858 ticks per display line (at PIX_CLK_DIV=2), which is plenty for
    // the 564 ticks it needs (4 warmup + 560 active).
    assign pixel_stream.pixel_clk_en = pix_tick_w;
    assign pixel_stream.hsync        = new_scanline_w;
    assign pixel_stream.vsync        = vsync_pulse_w;
    assign pixel_stream.scanline     = apple_scanline_w;

    // =========================================================================
    // Output mux — generator pixels when active, border color otherwise
    // =========================================================================

    assign video_r_o = pixel_stream.active ? pixel_stream.r : border_r_i;
    assign video_g_o = pixel_stream.active ? pixel_stream.g : border_g_i;
    assign video_b_o = pixel_stream.active ? pixel_stream.b : border_b_i;

endmodule
