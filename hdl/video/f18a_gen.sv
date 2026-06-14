`timescale 1ns / 1ps
//
// F18A VDP Generator — Pixel Stream Wrapper
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
// Wraps the F18A VDP core to produce a pixel stream output. Translates
// pixel_clk_en into raster_x_i/raster_y_i for the F18A core. The F18A
// core continues to run on its own clocks; this wrapper only adapts its
// output to the pixel stream interface.
//
// The F18A's transparent/ext_video signals map to the active output
// (active = !transparent when ext_video is high, i.e., the VDP has
// content to overlay on the Apple II video).
//

module f18a_gen (
    input wire clk_i,
    input wire reset_n_i,

    // Pixel stream interface
    pixel_stream_if.generator pixel_stream,

    // F18A core interface — directly wired through
    input wire [3:0] vdp_r_i,
    input wire [3:0] vdp_g_i,
    input wire [3:0] vdp_b_i,
    input wire       vdp_transparent_i,
    input wire       vdp_ext_video_i,

    // Raster position outputs for F18A core
    output reg [9:0] raster_x_o,
    output wire [9:0] raster_y_o
);

    // =========================================================================
    // Raster position generation
    // =========================================================================

    // raster_y comes directly from scanline (0-261)
    assign raster_y_o = {1'b0, pixel_stream.scanline};

    // raster_x advances on each pixel_clk_en, reset on hsync
    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            raster_x_o <= 10'd0;
        end else begin
            if (pixel_stream.hsync) begin
                raster_x_o <= 10'd0;
            end else if (pixel_stream.pixel_clk_en) begin
                raster_x_o <= raster_x_o + 10'd1;
            end
        end
    end

    // =========================================================================
    // Pixel output
    // =========================================================================

    // Expand 4-bit VDP RGB to 8-bit
    assign pixel_stream.r = {vdp_r_i, 4'h0};
    assign pixel_stream.g = {vdp_g_i, 4'h0};
    assign pixel_stream.b = {vdp_b_i, 4'h0};

    // Active when VDP has non-transparent content
    // ext_video indicates VDP wants to overlay; transparent indicates no VDP pixel
    assign pixel_stream.active = vdp_ext_video_i & ~vdp_transparent_i;

endmodule
