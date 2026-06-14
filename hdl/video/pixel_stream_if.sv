//
// Pixel Stream Interface
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
// Standard pixel stream interface for video generators. All signals are
// synchronous to the consumer's clock domain (typically clk_logic at 54 MHz).
//
// The consumer drives timing inputs (pixel_clk_en, hsync, vsync, scanline)
// and the generator responds with pixel outputs (r, g, b, active).
//
// pixel_clk_en is a clock enable, not a separate clock. On each cycle where
// pixel_clk_en is high, the generator advances its pixel pipeline and
// presents the next pixel on r/g/b.
//
// Consumer modes:
//   - Framebuffer: drives pixel_clk_en at framebuffer write rate
//   - Direct display: drives pixel_clk_en from display pixel clock
//   - Test mode: drives pixel_clk_en at any rate for verification
//

interface pixel_stream_if;

    // Timing inputs (consumer -> generator)
    logic       pixel_clk_en;   // Clock enable — advance one pixel when high
    logic       hsync;          // Scanline start pulse
    logic       vsync;          // Frame start pulse
    logic [8:0] scanline;       // Current scanline number (0-261)

    // Pixel outputs (generator -> consumer)
    logic [7:0] r;              // Red channel (RGB888)
    logic [7:0] g;              // Green channel (RGB888)
    logic [7:0] b;              // Blue channel (RGB888)
    logic       active;         // Generator is outputting active video

    modport generator (
        input  pixel_clk_en, hsync, vsync, scanline,
        output r, g, b, active
    );

    modport consumer (
        output pixel_clk_en, hsync, vsync, scanline,
        input  r, g, b, active
    );

endinterface
