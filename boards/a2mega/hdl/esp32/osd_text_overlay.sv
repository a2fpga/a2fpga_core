//
// OSD text overlay — renders the ESP32's 40x24 menu/console text page over
// the framebuffer output (clk_pixel domain).
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
// The a2n20v2-Enhanced BL616 shows its menu by writing the Apple II shadowed
// text page in SDRAM and flipping the video path. On the a2mega the shadow
// lives in DDR3 behind the port arbiter, so the ESP32 instead writes 40x24
// Apple II screen codes into a dedicated BSRAM page (XFER SPACE 1, linear
// y*40+x) and this module paints it directly over the 720x480 output —
// opaque when enabled, so the menu is visible even when the Apple II video
// path is dead.
//
// Characters are 7x8 Apple II glyphs from the shared video ROM (video.hex),
// scaled 2x to 14x16 cells: 40*14 = 560 x 24*16 = 384, centered in 720x480.
// Screen-code semantics (inverse $00-$3F, flash $40-$7F) match the Apple II.
//
// Each 14-pixel cell k prefetches the character for cell k+1: the text RAM
// read (registered, external port) and the font ROM read each take a cycle,
// and the assembled row byte is latched at the cell boundary. Cell 0 starts
// one cell before X_OFFSET so column 0 is prefetched during the border.
//
module osd_text_overlay #(
    parameter X_OFFSET = 80,   // (720 - 560) / 2
    parameter Y_OFFSET = 48    // (480 - 384) / 2
)(
    input  wire        clk_i,
    input  wire        reset_n,

    input  wire        enable_i,

    input  wire [10:0] screen_x_i,
    input  wire [9:0]  screen_y_i,

    // OSD text page read port (registered read in this clock domain)
    output reg  [10:0] vram_addr_o,
    input  wire [7:0]  vram_data_i,

    // RGB input and output
    input  wire [7:0]  r_i,
    input  wire [7:0]  g_i,
    input  wire [7:0]  b_i,

    output reg  [7:0]  r_o,
    output reg  [7:0]  g_o,
    output reg  [7:0]  b_o
);

    localparam CELL_W = 14;               // 7 glyph pixels x 2
    localparam [10:0] X_START = 11'(X_OFFSET - CELL_W);

    // ------------------------------------------------------------------------
    // Font ROM — shared Apple II video ROM, same addressing as apple_video_gen
    // ------------------------------------------------------------------------
    reg [7:0] viderom_r [4095:0];
    initial $readmemh("video.hex", viderom_r, 0);
    reg [11:0] viderom_a_r;
    reg [7:0]  viderom_d_r;
    always @(posedge clk_i) viderom_d_r <= ~viderom_r[viderom_a_r];

    // Flash cadence (~2 Hz at 27 MHz)
    reg [23:0] flash_cnt_r;
    always @(posedge clk_i) flash_cnt_r <= flash_cnt_r + 1'b1;
    wire flash_clk_w = flash_cnt_r[23];

    // Screen code -> ROM address (altchar = 0, matches apple_video_gen)
    function automatic bit [11:0] charRomAddr(
        input [7:0] char_byte,
        input [2:0] line
    );
        return {
            1'b0,
            char_byte[7] | (char_byte[6] & flash_clk_w),
            char_byte[6] & char_byte[7],
            char_byte[5:0],
            line
        };
    endfunction

    // ------------------------------------------------------------------------
    // Vertical position
    // ------------------------------------------------------------------------
    wire [9:0] rel_y = 10'(screen_y_i - Y_OFFSET);
    wire y_active = (screen_y_i >= Y_OFFSET) && (rel_y < 10'd384);
    wire [4:0] char_row = rel_y[8:4];     // 0-23
    wire [2:0] glyph_line = rel_y[3:1];   // 2x vertical scale

    // row * 40 = (row << 5) + (row << 3)
    wire [10:0] row_base = ({6'b0, char_row} << 5) + ({6'b0, char_row} << 3);

    // ------------------------------------------------------------------------
    // Horizontal cell walker with one-cell prefetch
    // ------------------------------------------------------------------------
    reg [3:0] subcnt_r;    // 0-13 within a cell
    reg [5:0] cell_r;      // 0 = prefetch cell (border), 1-40 = visible columns 0-39
    reg       running_r;

    reg [7:0] row_byte_r;  // glyph row currently being displayed

    always @(posedge clk_i or negedge reset_n) begin
        if (!reset_n) begin
            subcnt_r <= 4'd0;
            cell_r <= 6'd0;
            running_r <= 1'b0;
            vram_addr_o <= 11'd0;
            viderom_a_r <= 12'd0;
            row_byte_r <= 8'd0;
        end else begin
            if (screen_x_i == X_START) begin
                subcnt_r <= 4'd0;
                cell_r <= 6'd0;
                running_r <= y_active;
            end else if (running_r) begin
                if (subcnt_r == 4'd13) begin
                    subcnt_r <= 4'd0;
                    if (cell_r == 6'd40)
                        running_r <= 1'b0;
                    else
                        cell_r <= cell_r + 6'd1;
                end else begin
                    subcnt_r <= subcnt_r + 4'd1;
                end
            end

            // Prefetch pipeline for the character shown in the next cell:
            //   subcnt 0: address the text RAM (this cell's index = next column)
            //   subcnt 2: registered char code valid -> address the font ROM
            //   subcnt 4: registered glyph row valid (viderom_d_r)
            //   subcnt 13: latch it for display in the next cell
            if (running_r && cell_r < 6'd40) begin
                if (subcnt_r == 4'd0)
                    vram_addr_o <= row_base + {5'b0, cell_r};
                if (subcnt_r == 4'd2)
                    viderom_a_r <= charRomAddr(vram_data_i, glyph_line);
            end
            if (running_r && subcnt_r == 4'd13)
                row_byte_r <= (cell_r < 6'd40) ? viderom_d_r : 8'd0;
        end
    end

    // ------------------------------------------------------------------------
    // Pixel output — opaque when enabled
    // ------------------------------------------------------------------------
    wire in_text_w = running_r && (cell_r >= 6'd1);
    // Glyph bit 0 is the leftmost pixel; 2x horizontal scale
    wire pixel_w = in_text_w && row_byte_r[subcnt_r[3:1]];

    always @(posedge clk_i) begin
        if (enable_i) begin
            r_o <= pixel_w ? 8'hFF : 8'h00;
            g_o <= pixel_w ? 8'hFF : 8'h00;
            b_o <= pixel_w ? 8'hFF : 8'h00;
        end else begin
            r_o <= r_i;
            g_o <= g_i;
            b_o <= b_i;
        end
    end

endmodule
