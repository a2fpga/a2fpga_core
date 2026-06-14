`timescale 1ns / 1ps
//
// Apple IIgs Video Graphics Controller — Unified Generator
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
// Unified IIgs Super Hi-Res generator using the pixel stream interface.
// Based on vgc_fb.sv adapted to use pixel_clk_en gating.
//
// State machine: IDLE -> FETCH_SCB -> FETCH_PAL -> RENDER
// Supports 320x200 (4-bit, doubled to 640) and 640x200 (2-bit) modes.
// Per-scanline palette loading from VGC blockram.
//
// Outputs 640 pixels per visible scanline through pixel_stream_if.
//

module vgc_gen (
    input wire clk_i,
    input wire reset_n_i,

    // Apple II bus interfaces
    a2mem_if.slave a2mem_if,
    video_control_if.display video_control_if,

    // Pixel stream interface
    pixel_stream_if.generator pixel_stream,

    // VGC memory interface (to apple_memory DDR3 unified region)
    output        vgc_active_o,
    output reg [12:0] vgc_address_o,
    output reg        vgc_rd_o,
    input [31:0]      vgc_data_i,
    input             vgc_ready_i,

    // Diagnostic: count of hsync events that arrived while we were
    // still rendering a previous line (i.e. silently dropped lines).
    // Resets on vsync; saturates at 8'hFF.
    output reg [7:0]  dbg_missed_hsync_o
);

    // =========================================================================
    // VGC active signal — tells apple_memory to route aux BRAM to VGC
    // =========================================================================

    assign vgc_active_o = a2mem_if.SHRG_MODE;

    // =========================================================================
    // State machine
    // =========================================================================

    localparam ST_IDLE      = 3'd0;
    localparam ST_FETCH_SCB = 3'd1;
    localparam ST_FETCH_PAL = 3'd2;
    localparam ST_RENDER    = 3'd3;

    reg [2:0] state_r;
    reg [2:0] fetch_step_r;

    // =========================================================================
    // VRAM address constants
    // =========================================================================

    localparam [12:0] SCB_BASE     = 13'd8000;
    localparam [12:0] PALETTE_BASE = 13'd8064;

    // =========================================================================
    // Registers
    // =========================================================================

    reg shrg_mode_r;
    reg [7:0] render_line_r;
    reg [12:0] pix_addr_r;

    // SCB fields
    reg [7:0] scan_ctl_r;
    wire PIX640_w      = scan_ctl_r[7];
    wire COLOR_FILL_w  = scan_ctl_r[5];
    wire [3:0] palette_select_w = scan_ctl_r[3:0];

    // Palette
    reg [11:0] palette_rgb_r [0:15];
    reg [3:0] pal_fetch_cnt_r;

    // Pixel rendering
    reg [31:0] pixel_word_r;
    reg [5:0] pix_word_cnt_r;
    reg [3:0] pix_sub_cnt_r;
    reg [3:0] prev_palette_r;

    // Pixel output counter
    reg [9:0] pix_out_cnt_r;

    // =========================================================================
    // Pixel decode logic (from vgc_fb.sv)
    // =========================================================================

    wire [7:0] pix_byte_w = pix_sub_cnt_r[3:2] == 2'd3 ? pixel_word_r[31:24] :
                             pix_sub_cnt_r[3:2] == 2'd2 ? pixel_word_r[23:16] :
                             pix_sub_cnt_r[3:2] == 2'd1 ? pixel_word_r[15:8]  :
                             pixel_word_r[7:0];

    wire [3:0] pix320_w = pix_sub_cnt_r[1] ? pix_byte_w[3:0] : pix_byte_w[7:4];

    wire [1:0] pix640_w = pix_sub_cnt_r[1:0] == 2'd3 ? pix_byte_w[1:0] :
                           pix_sub_cnt_r[1:0] == 2'd2 ? pix_byte_w[3:2] :
                           pix_sub_cnt_r[1:0] == 2'd1 ? pix_byte_w[5:4] :
                           pix_byte_w[7:6];

    wire [1:0] pix640_palette_select_w = pix_sub_cnt_r[1:0] == 2'd3 ? 2'b01 :
                                          pix_sub_cnt_r[1:0] == 2'd2 ? 2'b00 :
                                          pix_sub_cnt_r[1:0] == 2'd1 ? 2'b11 :
                                          2'b10;

    wire [3:0] pix_palette_w = PIX640_w ? {pix640_palette_select_w, pix640_w} : pix320_w;

    wire [3:0] pix_fill_w = (COLOR_FILL_w && (pix_palette_w == 4'b0000)) ?
                             prev_palette_r : pix_palette_w;

    wire [11:0] pix_rgb_w = palette_rgb_r[pix_fill_w];

    // RGB888 output
    assign pixel_stream.r = {pix_rgb_w[11:8], 4'h0};
    assign pixel_stream.g = {pix_rgb_w[7:4], 4'h0};
    assign pixel_stream.b = {pix_rgb_w[3:0], 4'h0};

    // Active is combinational — high only when in RENDER step 4
    // (where r/g/b are valid). No registered delay means framebuffer_writer
    // sees active=1 on the same cycle as pixel_tick_w.
    assign pixel_stream.active = (state_r == ST_RENDER) && (fetch_step_r == 3'd4);

    // =========================================================================
    // Main state machine
    // =========================================================================

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            state_r <= ST_IDLE;
            fetch_step_r <= 3'd0;
            vgc_rd_o <= 1'b0;
            vgc_address_o <= 13'd0;
            shrg_mode_r <= 1'b0;
            render_line_r <= 8'd0;
            pix_addr_r <= 13'd0;
            scan_ctl_r <= 8'd0;
            pal_fetch_cnt_r <= 4'd0;
            pixel_word_r <= 32'd0;
            pix_word_cnt_r <= 6'd0;
            pix_sub_cnt_r <= 4'd0;
            prev_palette_r <= 4'd0;
            pix_out_cnt_r <= 10'd0;
            dbg_missed_hsync_o <= 8'd0;
        end else begin
            vgc_rd_o <= 1'b0;

            // Frame boundary
            if (pixel_stream.vsync) begin
                shrg_mode_r <= video_control_if.shrg_mode(a2mem_if.SHRG_MODE);
                // Reset per-frame missed-hsync counter on vsync
                dbg_missed_hsync_o <= 8'd0;
            end

            // Diagnostic: detect hsync arriving while we are NOT in
            // ST_IDLE (i.e. still rendering the previous line). Such
            // hsyncs are silently ignored, dropping a line.
            // Only count when SHRG mode is actually active.
            if (pixel_stream.hsync && shrg_mode_r && state_r != ST_IDLE) begin
                if (dbg_missed_hsync_o != 8'hFF)
                    dbg_missed_hsync_o <= dbg_missed_hsync_o + 8'd1;
            end

            case (state_r)

            // -----------------------------------------------------------------
            // IDLE — wait for hsync on a visible SHR scanline
            // -----------------------------------------------------------------
            ST_IDLE: begin
                if (pixel_stream.hsync && pixel_stream.scanline < 9'd200 && shrg_mode_r) begin
                    render_line_r <= pixel_stream.scanline[7:0];
                    pix_addr_r <= {5'b0, pixel_stream.scanline[7:0]} * 13'd40;
                    prev_palette_r <= 4'd0;
                    fetch_step_r <= 3'd0;
                    pix_out_cnt_r <= 10'd0;
                    state_r <= ST_FETCH_SCB;
                end
            end

            // -----------------------------------------------------------------
            // FETCH SCB — issue read, wait for ready, capture
            // -----------------------------------------------------------------
            ST_FETCH_SCB: begin
                case (fetch_step_r)
                    3'd0: begin
                        vgc_address_o <= SCB_BASE + {5'b0, render_line_r[7:2]};
                        vgc_rd_o <= 1'b1;
                        fetch_step_r <= 3'd1;
                    end
                    3'd1: begin
                        if (vgc_ready_i) begin
                            case (render_line_r[1:0])
                                2'd0: scan_ctl_r <= vgc_data_i[7:0];
                                2'd1: scan_ctl_r <= vgc_data_i[15:8];
                                2'd2: scan_ctl_r <= vgc_data_i[23:16];
                                2'd3: scan_ctl_r <= vgc_data_i[31:24];
                            endcase
                            pal_fetch_cnt_r <= 4'd0;
                            fetch_step_r <= 3'd0;
                            state_r <= ST_FETCH_PAL;
                        end
                    end
                    default: fetch_step_r <= 3'd0;
                endcase
            end

            // -----------------------------------------------------------------
            // FETCH PALETTE — 8 iterations, ready-based
            // -----------------------------------------------------------------
            ST_FETCH_PAL: begin
                case (fetch_step_r)
                    3'd0: begin
                        vgc_address_o <= PALETTE_BASE + {palette_select_w, 3'b000} + {9'b0, pal_fetch_cnt_r[2:0]};
                        vgc_rd_o <= 1'b1;
                        fetch_step_r <= 3'd1;
                    end
                    3'd1: begin
                        if (vgc_ready_i) begin
                            palette_rgb_r[{pal_fetch_cnt_r[2:0], 1'b0}] <= vgc_data_i[11:0];
                            pixel_word_r <= vgc_data_i;
                            fetch_step_r <= 3'd2;
                        end
                    end
                    3'd2: begin
                        palette_rgb_r[{pal_fetch_cnt_r[2:0], 1'b1}] <= pixel_word_r[27:16];

                        if (pal_fetch_cnt_r == 4'd7) begin
                            pix_word_cnt_r <= 6'd0;
                            pix_sub_cnt_r <= 4'd0;
                            fetch_step_r <= 3'd0;
                            state_r <= ST_RENDER;
                        end else begin
                            pal_fetch_cnt_r <= pal_fetch_cnt_r + 4'd1;
                            fetch_step_r <= 3'd0;
                        end
                    end
                    default: fetch_step_r <= 3'd0;
                endcase
            end

            // -----------------------------------------------------------------
            // RENDER — fetch pixel words (ready-based) and output pixels
            // -----------------------------------------------------------------
            ST_RENDER: begin
                case (fetch_step_r)
                    3'd0: begin
                        vgc_address_o <= pix_addr_r + {7'b0, pix_word_cnt_r};
                        vgc_rd_o <= 1'b1;
                        fetch_step_r <= 3'd1;
                    end
                    3'd1: begin
                        if (vgc_ready_i) begin
                            pixel_word_r <= vgc_data_i;
                            pix_sub_cnt_r <= 4'd0;
                            fetch_step_r <= 3'd4;
                        end
                    end
                    3'd4: begin
                        // Output one pixel per pixel_clk_en
                        if (pixel_stream.pixel_clk_en) begin
                            prev_palette_r <= pix_fill_w;
                            pix_out_cnt_r <= pix_out_cnt_r + 10'd1;

                            if (pix_sub_cnt_r == 4'd15) begin
                                pix_word_cnt_r <= pix_word_cnt_r + 6'd1;

                                if (pix_word_cnt_r == 6'd39) begin
                                    state_r <= ST_IDLE;
                                end else begin
                                    fetch_step_r <= 3'd0;
                                end
                            end else begin
                                pix_sub_cnt_r <= pix_sub_cnt_r + 4'd1;
                            end
                        end
                    end
                    default: fetch_step_r <= 3'd0;
                endcase
            end

            default: state_r <= ST_IDLE;

            endcase
        end
    end

endmodule
