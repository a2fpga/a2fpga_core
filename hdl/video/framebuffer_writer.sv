`timescale 1ns / 1ps
//
// Framebuffer Writer — Pixel Stream to Framebuffer Adapter
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
// Thin adapter that consumes a pixel_stream_if and produces the existing
// fb_we/fb_data/fb_vsync signals for framebuffer modules (sdram_framebuffer,
// ddr3_framebuffer_480p).
//
// Drives pixel_clk_en at 1-in-GAP_CYCLES rate on clk_i. Forwards hsync,
// vsync, and scanline from scan_timer to the generator through the pixel
// stream interface.
//
// Handles SuperSprite compositing between the generator and framebuffer:
// exposes apple_r/g/b for SuperSprite input, captures composited output
// after 1 cycle for combinational SSP path propagation.
//

module framebuffer_writer #(
    parameter GAP_CYCLES = 4  // pixel_clk_en asserted every GAP_CYCLES clk_i cycles
) (
    input wire clk_i,
    input wire reset_n_i,

    // Pixel stream interface (drives timing, receives pixels)
    pixel_stream_if.consumer pixel_stream,

    // Scan timer inputs
    input [8:0]  scanline_i,
    input        hsync_i,
    input        vsync_i,

    // Framebuffer write outputs
    output reg        fb_we_o,
    output reg [17:0] fb_data_o,    // RGB666
    output reg        fb_vsync_o,

    // Apple II RGB output for SuperSprite compositing
    output reg [7:0]  apple_r_o,
    output reg [7:0]  apple_g_o,
    output reg [7:0]  apple_b_o,
    output reg        apple_active_o,

    // SuperSprite composited input
    input [7:0]       ssp_r_i,
    input [7:0]       ssp_g_i,
    input [7:0]       ssp_b_i,
    input             ssp_active_i
);

    // =========================================================================
    // Clock enable generation — 1-in-GAP_CYCLES
    // =========================================================================

    reg [$clog2(GAP_CYCLES)-1:0] gap_cnt_r;

    wire pixel_tick_w = (gap_cnt_r == 0);

    always @(posedge clk_i) begin
        if (!reset_n_i || hsync_i) begin
            gap_cnt_r <= '0;
        end else begin
            if (gap_cnt_r == GAP_CYCLES - 1)
                gap_cnt_r <= '0;
            else
                gap_cnt_r <= gap_cnt_r + 1;
        end
    end

    // =========================================================================
    // Forward timing signals to generator
    // =========================================================================

    assign pixel_stream.pixel_clk_en = pixel_tick_w;
    assign pixel_stream.hsync        = hsync_i;
    assign pixel_stream.vsync        = vsync_i;
    assign pixel_stream.scanline     = scanline_i;

    // =========================================================================
    // Capture pixels and write to framebuffer
    // =========================================================================

    // SSP capture pipeline: pixel_stream outputs on pixel_tick_w,
    // we expose to SSP on tick+1, capture SSP result on tick+2.

    reg ssp_capture_r;
    reg pixel_pending_r;

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            fb_we_o <= 1'b0;
            fb_vsync_o <= 1'b0;
            fb_data_o <= 18'd0;
            apple_r_o <= 8'd0;
            apple_g_o <= 8'd0;
            apple_b_o <= 8'd0;
            apple_active_o <= 1'b0;
            ssp_capture_r <= 1'b0;
            pixel_pending_r <= 1'b0;
        end else begin
            fb_we_o <= 1'b0;
            fb_vsync_o <= 1'b0;
            apple_active_o <= 1'b0;

            // Vsync pass-through
            if (vsync_i) begin
                fb_vsync_o <= 1'b1;
            end

            // SSP capture: 1 cycle after exposing apple RGB, SSP path has settled
            if (ssp_capture_r) begin
                fb_data_o <= {ssp_r_i[7:2], ssp_g_i[7:2], ssp_b_i[7:2]};
                fb_we_o <= 1'b1;
                ssp_capture_r <= 1'b0;
            end

            // On pixel tick: capture generator output
            if (pixel_tick_w && pixel_stream.active) begin
                // Expose to SuperSprite
                apple_r_o <= pixel_stream.r;
                apple_g_o <= pixel_stream.g;
                apple_b_o <= pixel_stream.b;
                apple_active_o <= 1'b1;

                if (ssp_active_i) begin
                    // Defer write by 1 cycle for SSP combinational path
                    ssp_capture_r <= 1'b1;
                end else begin
                    // Direct write — convert RGB888 to RGB666
                    fb_data_o <= {pixel_stream.r[7:2], pixel_stream.g[7:2], pixel_stream.b[7:2]};
                    fb_we_o <= 1'b1;
                end
            end
        end
    end

endmodule

