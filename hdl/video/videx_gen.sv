//
// Videx VideoTerm 80-column pixel-stream generator
//
// Copyright (c) 2026 Brent Rector
// Copyright (c) 2026 the A2FPGA contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Description:
//
// Renders the Videx 80x24 text screen into pixel_stream_if (see
// docs/video-pipeline.md): 640 active pixels (80 cols x 8) on each of
// scanlines 0-215 (24 rows x 9 lines). The consumer is a framebuffer_writer
// feeding a 640x216 framebuffer plane; the Apple's own 192 visible lines are
// irrelevant here -- a Videx drives its own monitor timing, and lines
// 192-215 simply fall in the Apple's vertical blank.
//
// Rendering rules (character ROM layout, inverse-by-bit-7, cursor XOR and
// blink, IIgs-style palette) follow Brent Rector's hardware-verified
// raster renderer (BrentRector/a2fpga_core, hdl/videx/videx_card.sv).
//
// Pipeline: a small fetch FSM prepares the NEXT character's glyph while the
// current one shifts out. A fetch takes ~6 clk; a character occupies 8
// pixel ticks (>= 16 clk at any legal pixel_clk_en cadence), so the next
// glyph is always ready. r/g/b and active are registered together on the
// tick, giving the consumer a consistent one-tick-latency pair.
//
// The character ROM is 128 glyphs x 16 lines, bit-reversed (bit 0 = leftmost
// pixel); codes $80-$FF are the inverse of $00-$7F.
//

module videx_gen (
    input wire clk_i,
    input wire reset_n_i,

    a2mem_if.slave a2mem_if,                // TEXT/BACKGROUND colors
    input wire sw_gs_i,                     // palette select (0 Apple II, 1 IIgs)

    pixel_stream_if.generator pixel_stream,

    input wire        videx_mode_i,         // card live && TEXT && AN0
    input wire [7:0]  crtc_r10_i,
    input wire [7:0]  crtc_r11_i,
    input wire [10:0] start_addr_i,
    input wire [10:0] cursor_addr_i,

    output reg        vram_rd_o,
    output reg [8:0]  vram_addr_o,
    input wire [31:0] vram_data_i,
    input wire        vram_valid_i,

    output wire       videx_active_o        // frame-latched mode (plane select)
);

    localparam [8:0] LINES = 9'd216;        // 24 rows x 9 scanlines
    localparam [6:0] COLS  = 7'd80;
    localparam [9:0] WIDTH = 10'd640;

    // ------------------------------------------------------------------
    // Character ROM (2 KB)
    // ------------------------------------------------------------------
    reg [7:0]  charrom[0:2047];
    initial $readmemh("videx_charrom.hex", charrom);
    reg [10:0] rom_a_r;
    reg [7:0]  rom_d_r;
    always @(posedge clk_i) rom_d_r <= charrom[rom_a_r];

    // ------------------------------------------------------------------
    // Frame latches (vsync)
    // ------------------------------------------------------------------
    reg        mode_r;
    reg [10:0] start_r, cursor_r;
    reg [7:0]  r10_r, r11_r;
    reg [3:0]  fg_r, bg_r;
    reg        gsp_r;
    reg [5:0]  frame_cnt_r;

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            mode_r      <= 1'b0;
            frame_cnt_r <= 6'd0;
        end else if (pixel_stream.vsync) begin
            mode_r      <= videx_mode_i;
            start_r     <= start_addr_i;
            cursor_r    <= cursor_addr_i;
            r10_r       <= crtc_r10_i;
            r11_r       <= crtc_r11_i;
            fg_r        <= a2mem_if.TEXT_COLOR;
            bg_r        <= a2mem_if.BACKGROUND_COLOR;
            gsp_r       <= sw_gs_i;
            frame_cnt_r <= frame_cnt_r + 6'd1;
        end
    end

    assign videx_active_o = mode_r;

    // MC6845 cursor: R10[6:5] 00 steady, 01 off, 10/11 blink (fast/slow)
    wire cursor_blink_w = (r10_r[6:5] == 2'b00) ? 1'b1 :
                          (r10_r[6:5] == 2'b01) ? 1'b0 :
                          (r10_r[6:5] == 2'b10) ? frame_cnt_r[3] :
                                                  frame_cnt_r[4];

    // ------------------------------------------------------------------
    // Per-line state
    // ------------------------------------------------------------------
    reg        line_on_r;
    reg [3:0]  sub_r;            // scanline within the character row, 0-8
    reg [10:0] line_base_r;      // VRAM address of column 0 of this row
    reg [6:0]  fetch_idx_r;      // next column to fetch
    reg        cursor_line_r;    // this scanline is inside the cursor block

    // row = scanline / 9 via (y * 57) >> 9, exact for 0-215
    wire [7:0]  y_w      = pixel_stream.scanline[7:0];
    wire [13:0] div9_w   = y_w * 8'd57;
    wire [4:0]  row_w    = div9_w[13:9];
    wire [7:0]  row_x9_w = {row_w, 3'b0} + {3'b0, row_w};
    wire [3:0]  sub_w    = 4'(y_w - row_x9_w);
    wire [10:0] row_x80_w = {row_w, 6'd0} + {2'b0, row_w, 4'd0};

    // Fetch FSM
    localparam [2:0] F_IDLE = 3'd0, F_WAIT = 3'd1, F_ROM = 3'd2, F_GLYPH = 3'd3;
    reg [2:0]  fstate_r;
    reg [1:0]  byte_sel_r;
    reg        cursor_hit_r;
    reg        invert_r;
    reg [7:0]  next_glyph_r;
    reg        next_valid_r;

    wire [10:0] char_addr_w = (line_base_r + {4'd0, fetch_idx_r}) & 11'h7FF;

    // Output shifter
    reg [7:0]  cur_glyph_r;
    reg        cur_valid_r;
    reg [2:0]  bit_r;
    reg [9:0]  out_cnt_r;

    reg [11:0] palette_rgb_r[0:31] = '{
        12'h000, 12'h924, 12'h42a, 12'hd4e,
        12'h064, 12'h888, 12'h39e, 12'hcbf,
        12'h450, 12'hc73, 12'h888, 12'hfac,
        12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,
        12'h000, 12'hd03, 12'h009, 12'hd2d,
        12'h072, 12'h555, 12'h22f, 12'h6af,
        12'h850, 12'hf60, 12'haaa, 12'hf98,
        12'h1d0, 12'hff0, 12'h4f9, 12'hfff
    };

    wire [11:0] fg_rgb_w = palette_rgb_r[{gsp_r, fg_r}];
    wire [11:0] bg_rgb_w = palette_rgb_r[{gsp_r, bg_r}];
    wire        pix_w    = cur_glyph_r[bit_r];
    wire [11:0] pix_rgb_w = pix_w ? fg_rgb_w : bg_rgb_w;

    reg        out_active_r;
    reg [11:0] out_rgb_r;
    assign pixel_stream.active = out_active_r;
    assign pixel_stream.r = {out_rgb_r[11:8], 4'h0};
    assign pixel_stream.g = {out_rgb_r[7:4],  4'h0};
    assign pixel_stream.b = {out_rgb_r[3:0],  4'h0};

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            line_on_r          <= 1'b0;
            fstate_r           <= F_IDLE;
            vram_rd_o          <= 1'b0;
            next_valid_r       <= 1'b0;
            cur_valid_r        <= 1'b0;
            out_cnt_r          <= 10'd0;
            out_active_r       <= 1'b0;
            out_rgb_r          <= 12'd0;
        end else begin
            vram_rd_o <= 1'b0;

            // ---- line start ----
            if (pixel_stream.hsync) begin
                line_on_r     <= mode_r && (pixel_stream.scanline < LINES);
                sub_r         <= sub_w;
                line_base_r   <= (start_r + row_x80_w) & 11'h7FF;
                cursor_line_r <= cursor_blink_w &&
                                 (sub_w >= r10_r[3:0]) && (sub_w <= r11_r[3:0]);
                fetch_idx_r   <= 7'd0;
                fstate_r      <= F_IDLE;
                next_valid_r  <= 1'b0;
                cur_valid_r   <= 1'b0;
                bit_r         <= 3'd0;
                out_cnt_r     <= 10'd0;
            end else if (line_on_r) begin

                // ---- fetch the next glyph ----
                case (fstate_r)
                    F_IDLE: if (!next_valid_r && fetch_idx_r < COLS) begin
                        vram_rd_o    <= 1'b1;
                        vram_addr_o  <= char_addr_w[10:2];
                        byte_sel_r   <= char_addr_w[1:0];
                        cursor_hit_r <= cursor_line_r && (char_addr_w == cursor_r);
                        fstate_r     <= F_WAIT;
                    end
                    F_WAIT: if (vram_valid_i) begin
                        case (byte_sel_r)
                            2'd0: begin rom_a_r <= {vram_data_i[6:0],   sub_r}; invert_r <= vram_data_i[7]  ^ cursor_hit_r; end
                            2'd1: begin rom_a_r <= {vram_data_i[14:8],  sub_r}; invert_r <= vram_data_i[15] ^ cursor_hit_r; end
                            2'd2: begin rom_a_r <= {vram_data_i[22:16], sub_r}; invert_r <= vram_data_i[23] ^ cursor_hit_r; end
                            2'd3: begin rom_a_r <= {vram_data_i[30:24], sub_r}; invert_r <= vram_data_i[31] ^ cursor_hit_r; end
                        endcase
                        fstate_r <= F_ROM;
                    end
                    F_ROM:   fstate_r <= F_GLYPH;      // rom_d_r settles
                    F_GLYPH: begin
                        next_glyph_r <= rom_d_r ^ {8{invert_r}};
                        next_valid_r <= 1'b1;
                        fetch_idx_r  <= fetch_idx_r + 7'd1;
                        fstate_r     <= F_IDLE;
                    end
                    default: fstate_r <= F_IDLE;
                endcase

                // ---- prime the shifter with column 0 ----
                if (!cur_valid_r && out_cnt_r == 10'd0 && next_valid_r) begin
                    cur_glyph_r  <= next_glyph_r;
                    cur_valid_r  <= 1'b1;
                    next_valid_r <= 1'b0;
                end
            end

            // ---- pixel output (one per tick) ----
            if (pixel_stream.pixel_clk_en) begin
                if (line_on_r && cur_valid_r && out_cnt_r < WIDTH && !pixel_stream.hsync) begin
                    out_active_r <= 1'b1;
                    out_rgb_r    <= pix_rgb_w;
                    out_cnt_r <= out_cnt_r + 10'd1;
                    bit_r     <= bit_r + 3'd1;
                    if (bit_r == 3'd7) begin
                        // next glyph is always ready (fetch << 8 ticks)
                        cur_glyph_r  <= next_glyph_r;
                        next_valid_r <= 1'b0;
                    end
                end else begin
                    out_active_r <= 1'b0;
                end
            end
        end
    end

endmodule
