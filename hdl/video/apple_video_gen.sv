`timescale 1ns / 1ps
//
// Apple II Unified Video Generator
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
// Unified Apple II video generator using the pixel stream interface.
// Based on apple_video.sv (the working real-time implementation) adapted
// to use pixel_clk_en as a clock enable instead of running on clk_pixel.
//
// Runs on clk_logic with pixel_clk_en gating pixel-rate advancement.
// Same chunk-based fetch/expand pipeline (28-pixel chunks), same palette
// ROM, artifact ROM, and nibble computation as apple_video.sv.
//
// The consumer drives pixel_clk_en at whatever rate it needs:
//   - Framebuffer: 1-in-N at clk_logic rate
//   - Direct display: pixel clock rate as enable on clk_logic
//
// VRAM read interface is separate from the pixel stream (not part of the
// interface). SuperSprite compositing is handled externally by the consumer.
//

module apple_video_gen #(
    parameter VRAM_READ_LATENCY = 2,  // (unused, kept for documentation) 2=BSRAM, ~16=SDRAM
    parameter PIXEL_START_TICK = 0    // 0=immediate (BSRAM), >0=fixed delay in pixel_clk_en ticks
                                      // after hsync before pixel output begins, for deterministic
                                      // SSP overlay timing when SDRAM priming latency varies
) (
    input wire clk_i,
    input wire reset_n_i,

    // Apple II bus interfaces (for mode registers and GS switch)
    a2mem_if.slave a2mem_if,
    video_control_if.display video_control_if,
    input wire sw_gs_i,

    // Pixel stream interface
    pixel_stream_if.generator pixel_stream,

    // VRAM read interface (directly to apple_memory)
    output reg [15:0] video_address_o,
    output reg video_bank_o,
    output reg video_rd_o,
    input [31:0] video_data_i,
    input wire video_ready_i       // VRAM data ready (active-high, tie 1 for BSRAM)
);

    localparam FORCE_NIBBLE_COLORS = 1;
    localparam FORCE_MONOCHROME = 0;
    localparam FORCE_GS_PALETTE = 0;

    localparam NUM_CHUNKS = 20;          // 560 / 28
    localparam STEP_LENGTH = 28;
    localparam PIX_BUFFER_SIZE = STEP_LENGTH + 1; // 29
    localparam PIX_HISTORY_SIZE = 8;

    localparam HISTORY_ARTIFACT_OFFSET = 1;
    localparam HISTORY_PIXEL_OFFSET = 4;

    // Number of pixel cycles to run before enabling output.
    // Must match HISTORY_PIXEL_OFFSET so pix_history_r is primed.
    localparam WARMUP_PIXELS = 4;

    // ----------------------------------------------------------------------------------------------------------------
    // Video ROM — registered read, 2-cycle latency (set addr@N, valid@N+2)
    // ----------------------------------------------------------------------------------------------------------------

    reg [7:0] viderom_r[4095:0];
    initial $readmemh("video.hex", viderom_r, 0);
    reg [11:0] viderom_a_r;
    reg [7:0] viderom_d_r;
    always @(posedge clk_i) viderom_d_r <= ~viderom_r[viderom_a_r];

    reg [22:0] flash_cnt_r;
    always @(posedge clk_i) flash_cnt_r <= flash_cnt_r + 1'b1;
    wire flash_clk_w = flash_cnt_r[22];

    // ----------------------------------------------------------------------------------------------------------------
    // Utility functions — verbatim from apple_video.sv
    // ----------------------------------------------------------------------------------------------------------------

    // Regular Hires
    function automatic bit [28:0] expandHires40([31:0] vd);
        reg [28:0] vs;
        case ({vd[23],vd[7]})
            2'b00: vs = {
                            1'b0,
                            vd[22],vd[22],vd[21],vd[21],
                            vd[20],vd[20],vd[19],vd[19],
                            vd[18],vd[18],vd[17],vd[17],
                            vd[16],vd[16],vd[6],vd[6],
                            vd[5],vd[5],vd[4],vd[4],
                            vd[3],vd[3],vd[2],vd[2],
                            vd[1],vd[1],vd[0],vd[0]
            };
            2'b01: vs = {
                            1'b0,
                            vd[22],vd[22],vd[21],vd[21],
                            vd[20],vd[20],vd[19],vd[19],
                            vd[18],vd[18],vd[17],vd[17],
                            vd[16],vd[16],vd[6],vd[5],
                            vd[5],vd[4],vd[4],vd[3],
                            vd[3],vd[2],vd[2],vd[1],
                            vd[1],vd[0],vd[0],1'b0
            };
            2'b10: vs = {
                            vd[22],
                            vd[22],vd[21],vd[21],vd[20],
                            vd[20],vd[19],vd[19],vd[18],
                            vd[18],vd[17],vd[17],vd[16],
                            vd[16],vd[16] & vd[6],vd[6],vd[6],
                            vd[5],vd[5],vd[4],vd[4],
                            vd[3],vd[3],vd[2],vd[2],
                            vd[1],vd[1],vd[0],vd[0]
            };
            2'b11: vs = {
                            vd[22],
                            vd[22],vd[21],vd[21],vd[20],
                            vd[20],vd[19],vd[19],vd[18],
                            vd[18],vd[17],vd[17],vd[16],
                            vd[16],vd[6],vd[6],vd[5],
                            vd[5],vd[4],vd[4],vd[3],
                            vd[3],vd[2],vd[2],vd[1],
                            vd[1],vd[0],vd[0],1'b0
            };
        endcase
        return vs;
    endfunction

    // Double Hires
    function automatic bit [27:0] expandHires80([31:0] vd);
        reg [27:0] vs;
        vs = {
                vd[22:16],
                vd[30:24],
                vd[6:0],
                vd[14:8]
            };
        return vs;
    endfunction

    // Text expansion (character ROM byte -> 14 doubled pixels)
    function automatic bit [13:0] expandText40([7:0] vd);
        reg [13:0] vs;
        vs = {
            vd[6],vd[6],
            vd[5],vd[5],
            vd[4],vd[4],
            vd[3],vd[3],
            vd[2],vd[2],
            vd[1],vd[1],
            vd[0],vd[0]
        };
        return vs;
    endfunction

    // Regular Lores
    function automatic bit [27:0] expandLores40([31:0] vd, bit seg);
        reg [27:0] vs;
        case (seg)
            1'b0: vs = {
                vd[19],vd[18],vd[17],vd[16],
                vd[19],vd[18],vd[17],vd[16],
                vd[19],vd[18],vd[17],vd[16],
                vd[19],vd[18],vd[1],vd[0],
                vd[3],vd[2],vd[1],vd[0],
                vd[3],vd[2],vd[1],vd[0],
                vd[3],vd[2],vd[1],vd[0]
            };
            1'b1: vs = {
                vd[23],vd[22],vd[21],vd[20],
                vd[23],vd[22],vd[21],vd[20],
                vd[23],vd[22],vd[21],vd[20],
                vd[23],vd[22],vd[5],vd[4],
                vd[7],vd[6],vd[5],vd[4],
                vd[7],vd[6],vd[5],vd[4],
                vd[7],vd[6],vd[5],vd[4]
            };
        endcase
        return vs;
    endfunction

    // Double Lores
    function automatic bit [27:0] expandLores80([31:0] vd, bit seg);
        reg [27:0] vs;
        case (seg)
            1'b0: vs = {
                vd[16],vd[19],vd[18],vd[17],
                vd[16],vd[19],vd[18],vd[24],
                vd[27],vd[26],vd[25],vd[24],
                vd[27],vd[26],vd[2],vd[1],
                vd[0],vd[3],vd[2],vd[1],
                vd[0],vd[10],vd[9],vd[8],
                vd[11],vd[10],vd[9],vd[8]
            };
            1'b1: vs = {
                vd[20],vd[23],vd[22],vd[21],
                vd[20],vd[23],vd[22],vd[28],
                vd[31],vd[30],vd[29],vd[28],
                vd[31],vd[30],vd[6],vd[5],
                vd[4],vd[7],vd[6],vd[5],
                vd[4],vd[14],vd[13],vd[12],
                vd[15],vd[14],vd[13],vd[12]
            };
        endcase
        return vs;
    endfunction

    // Memory address generation, per Sather
    function automatic bit [15:0] lineaddr([9:0] y, input gr);
        reg [15:0] a;
        a[2:0] = 4'b0;
        a[6:3] = ({ 1'b1, y[6], 1'b1, 1'b1}) +
                 ({ y[7], 1'b1, y[7], 1'b1}) +
                 ({ 3'b000,           y[6]});
        a[9:7] = y[5:3];
        a[14:10] = (hires_mode_r & gr) == 1'b0 ?
            {2'b00, 1'b0, page2_r &  ~store80_r, ~(page2_r &  ~store80_r)} :
            {page2_r &  ~store80_r, ~(page2_r &  ~store80_r), y[2:0]};
        a[15] = 1'b0;
        return a;
    endfunction

    // ----------------------------------------------------------------------------------------------------------------
    // Mode registers — latched once per frame at vsync
    // ----------------------------------------------------------------------------------------------------------------

    reg text_mode_r;
    reg page2_r;
    reg hires_mode_r;
    reg mixed_mode_r;
    reg col80_r;
    reg store80_r;
    reg an3_r;
    reg altchar_r;
    reg video_bank_r;

    reg [3:0] text_color_r;
    reg [3:0] background_color_r;
    reg monochrome_mode_r;
    reg monochrome_dhires_mode_r;
    reg shrg_mode_r;

    // ----------------------------------------------------------------------------------------------------------------
    // Line type
    // ----------------------------------------------------------------------------------------------------------------

    reg [7:0] render_line_r;     // Apple II line 0-191
    wire GR = ~(text_mode_r | (render_line_r[5] & render_line_r[7] & mixed_mode_r));

    localparam [2:0] TEXT40_LINE = 0;
    localparam [2:0] TEXT80_LINE = 1;
    localparam [2:0] LORES40_LINE = 4;
    localparam [2:0] LORES80_LINE = 5;
    localparam [2:0] HIRES40_LINE = 6;
    localparam [2:0] HIRES80_LINE = 7;

    wire [2:0] line_type_w = (!GR & !col80_r) ? TEXT40_LINE :
        (!GR & col80_r) ? TEXT80_LINE :
        (GR & !hires_mode_r & an3_r) ? LORES40_LINE :
        (GR & col80_r & !hires_mode_r & !an3_r) ? LORES80_LINE :
        (GR & !col80_r & hires_mode_r & an3_r) ? HIRES40_LINE :
        (GR & col80_r & hires_mode_r & !an3_r) ? HIRES80_LINE :
        TEXT40_LINE;

    wire lores_line_type_w = (line_type_w == LORES40_LINE) | (line_type_w == LORES80_LINE);

    // ----------------------------------------------------------------------------------------------------------------
    // Color pipeline
    // ----------------------------------------------------------------------------------------------------------------

    wire GSP = FORCE_GS_PALETTE | sw_gs_i;

    reg [11:0] palette_rgb_r[0:31] = '{
        12'h000, 12'h924, 12'h42a, 12'hd4e,
        12'h064, 12'h888, 12'h39e, 12'hcbf,
        12'h450, 12'hc73, 12'h888, 12'hfac,
        12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,
        12'h000, 12'hd03, 12'h009, 12'hd2d,
        12'h072, 12'h555, 12'h22f, 12'h6af,
        12'h850, 12'hf60, 12'haaa, 12'hf98,
        12'h1d0, 12'hff0, 12'h4f9, 12'hfff
    } /* synthesis syn_romstyle = "distributed_rom" */;

    reg [3:0] artifact_r[0:127] = '{
        4'h0,4'h0,4'h0,4'h0,4'h8,4'h0,4'h0,4'h0,4'h1,4'h1,4'h5,4'h1,4'h9,4'h9,4'hd,4'hf,
        4'h2,4'h2,4'h6,4'h6,4'ha,4'ha,4'he,4'he,4'h3,4'h3,4'h3,4'h3,4'hb,4'hb,4'hf,4'hf,
        4'h0,4'h0,4'h4,4'h4,4'hc,4'hc,4'hc,4'hc,4'h5,4'h5,4'h5,4'h5,4'h9,4'h9,4'hd,4'hf,
        4'h0,4'h2,4'h6,4'h6,4'he,4'ha,4'he,4'he,4'h7,4'h7,4'h7,4'h7,4'hf,4'hf,4'hf,4'hf,
        4'h0,4'h0,4'h0,4'h0,4'h8,4'h8,4'h8,4'h8,4'h1,4'h1,4'h5,4'h1,4'h9,4'h9,4'hd,4'hf,
        4'h0,4'h2,4'h6,4'h6,4'ha,4'ha,4'ha,4'ha,4'h3,4'h3,4'h3,4'h3,4'hb,4'hb,4'hf,4'hf,
        4'h0,4'h0,4'h4,4'h4,4'hc,4'hc,4'hc,4'hc,4'h1,4'h1,4'h5,4'h5,4'h9,4'h9,4'hd,4'hd,
        4'h0,4'h2,4'h6,4'h6,4'he,4'ha,4'he,4'he,4'hf,4'hf,4'hf,4'h7,4'hf,4'hf,4'hf,4'hf
    };

    wire BW = FORCE_MONOCHROME | monochrome_mode_r | monochrome_dhires_mode_r;

    // Combinational artifact lookup
    wire [6:0] artifact_window_w = pix_history_r[HISTORY_ARTIFACT_OFFSET + 6:HISTORY_ARTIFACT_OFFSET];
    wire [3:0] artifact_data_w = artifact_r[artifact_window_w];

    // ----------------------------------------------------------------------------------------------------------------
    // Nibble helper
    // ----------------------------------------------------------------------------------------------------------------

    function automatic bit [3:0] calcNibble(
        input [PIX_HISTORY_SIZE-1:0] hist,
        input is_lores,
        input [2:0] step7,
        input [1:0] step4,
        input [3:0] prev_nibble
    );
        reg [3:0] n;
        if (is_lores & (step7 == 3'd4)) begin
            case (step4)
                2'b00: n = hist[7:4];
                2'b01: n = {hist[6:4], hist[7]};
                2'b10: n = {hist[5:4], hist[7:6]};
                2'b11: n = {hist[4], hist[7:5]};
            endcase
        end else if (!is_lores & (step4 == 2'd0)) begin
            n = hist[7:4];
        end else begin
            n = prev_nibble;
        end
        return n;
    endfunction

    // ----------------------------------------------------------------------------------------------------------------
    // Character ROM address helper
    // ----------------------------------------------------------------------------------------------------------------

    function automatic bit [11:0] charRomAddr(
        input [7:0] char_byte,
        input [2:0] line
    );
        return {
            1'b0,
            char_byte[7] | (char_byte[6] & flash_clk_w & ~altchar_r),
            char_byte[6] & (altchar_r | char_byte[7]),
            char_byte[5:0],
            line
        };
    endfunction

    // ----------------------------------------------------------------------------------------------------------------
    // State machine
    // ----------------------------------------------------------------------------------------------------------------

    localparam ST_IDLE   = 1'b0;
    localparam ST_ACTIVE = 1'b1;

    reg state_r;

    // Inline pipeline counters
    reg [4:0] chunk_r;           // current output chunk (0-19)
    reg [4:0] pix_cnt_r;         // pixel position within chunk (0-27)
    reg [3:0] fe_step_r;         // fetch/expand pipeline step
    reg       fe_done_r;         // fetch/expand complete for next chunk
    reg       primed_r;          // first chunk loaded, pixel output active

    // Working registers for fetch/expand pipeline
    reg [PIX_BUFFER_SIZE-1:0] next_pix_buffer_r;
    reg       next_pix_delay_r;
    reg [31:0] video_data_r;
    reg [5:0] h_offset_r;
    reg [4:0] fe_chunk_r;

    // Scanline pixel counter — gates output at exactly 560 pixels
    reg [9:0] scanline_pix_cnt_r;

    // Pixel tick counter since hsync — for PIXEL_START_TICK delay
    reg [4:0] hsync_tick_cnt_r;
    wire pixel_start_ok_w = (PIXEL_START_TICK == 0) || (hsync_tick_cnt_r >= PIXEL_START_TICK);

    // Pixel pipeline
    reg [PIX_BUFFER_SIZE-1:0] pix_shift_r /* synthesis syn_srlstyle = "registers" */;
    reg [PIX_HISTORY_SIZE-1:0] pix_history_r /* synthesis syn_srlstyle = "registers" */;

    reg       pix_delay_r;
    reg [1:0] pix_step4_r;
    reg [2:0] pix_step7_r;
    reg [3:0] pix_nibble_r;
    reg [3:0] pix_color_r;

    // Line address base
    reg [15:0] line_base_r;

    // Pre-registered artifact and nibble (for timing closure)
    reg [3:0] rot_artifact_pre_r;
    reg [3:0] nibble_pre_r;

    always @(posedge clk_i) begin
        case (pix_step4_r)
            2'b00: rot_artifact_pre_r <= artifact_data_w;
            2'b01: rot_artifact_pre_r <= {artifact_data_w[2:0], artifact_data_w[3]};
            2'b10: rot_artifact_pre_r <= {artifact_data_w[1:0], artifact_data_w[3:2]};
            2'b11: rot_artifact_pre_r <= {artifact_data_w[0], artifact_data_w[3:1]};
        endcase
        nibble_pre_r <= calcNibble(pix_history_r, lores_line_type_w, pix_step7_r, pix_step4_r, pix_nibble_r);
    end

    // ----------------------------------------------------------------------------------------------------------------
    // GR computed from incoming scanline (for use at IDLE -> ACTIVE transition)
    // ----------------------------------------------------------------------------------------------------------------

    wire visible_w = (pixel_stream.scanline < 9'd192);
    wire next_GR = ~(text_mode_r | (pixel_stream.scanline[5] & pixel_stream.scanline[7] & mixed_mode_r));

    wire [2:0] next_line_type_w = (!next_GR & !col80_r) ? TEXT40_LINE :
        (!next_GR & col80_r) ? TEXT80_LINE :
        (next_GR & !hires_mode_r & an3_r) ? LORES40_LINE :
        (next_GR & col80_r & !hires_mode_r & !an3_r) ? LORES80_LINE :
        (next_GR & !col80_r & hires_mode_r & an3_r) ? HIRES40_LINE :
        (next_GR & col80_r & hires_mode_r & !an3_r) ? HIRES80_LINE :
        TEXT40_LINE;

    // ----------------------------------------------------------------------------------------------------------------
    // Pixel output — RGB888 from palette
    // ----------------------------------------------------------------------------------------------------------------

    wire [11:0] pix_rgb_w = palette_rgb_r[{GSP, pix_color_r}];

    assign pixel_stream.r = {pix_rgb_w[11:8], 4'h0};
    assign pixel_stream.g = {pix_rgb_w[7:4], 4'h0};
    assign pixel_stream.b = {pix_rgb_w[3:0], 4'h0};

    // active is registered inside the state machine
    reg pixel_active_r;
    assign pixel_stream.active = pixel_active_r;

    // ----------------------------------------------------------------------------------------------------------------
    // Main state machine — runs on clk_i, gated by pixel_clk_en for pixel output
    // ----------------------------------------------------------------------------------------------------------------

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            state_r <= ST_IDLE;
            pixel_active_r <= 1'b0;
            video_rd_o <= 1'b0;
            video_address_o <= 16'd0;
            video_bank_o <= 1'b0;
            viderom_a_r <= 12'd0;

            chunk_r <= 5'd0;
            pix_cnt_r <= 5'd0;
            fe_step_r <= 4'd0;
            fe_done_r <= 1'b0;
            primed_r <= 1'b0;
            fe_chunk_r <= 5'd0;
            next_pix_buffer_r <= '0;
            next_pix_delay_r <= 1'b0;
            video_data_r <= 32'd0;
            h_offset_r <= 6'd0;
            scanline_pix_cnt_r <= 10'd0;
            hsync_tick_cnt_r <= 5'd0;

            pix_shift_r <= '0;
            pix_history_r <= '0;
            pix_delay_r <= 1'b0;
            pix_step4_r <= 2'd0;
            pix_step7_r <= 3'd0;
            pix_nibble_r <= 4'd0;
            pix_color_r <= 4'd0;
            render_line_r <= 8'd0;
            line_base_r <= 16'd0;

            text_mode_r <= 1'b1;
            page2_r <= 1'b0;
            hires_mode_r <= 1'b0;
            mixed_mode_r <= 1'b0;
            col80_r <= 1'b0;
            store80_r <= 1'b0;
            an3_r <= 1'b1;
            altchar_r <= 1'b0;
            video_bank_r <= 1'b0;
            text_color_r <= 4'hF;
            background_color_r <= 4'h0;
            monochrome_mode_r <= 1'b0;
            monochrome_dhires_mode_r <= 1'b0;
            shrg_mode_r <= 1'b0;
        end else begin

            video_rd_o <= 1'b0;

            // Vsync: latch mode registers
            if (pixel_stream.vsync) begin
                video_bank_r             <= video_control_if.enable;
                text_mode_r             <= video_control_if.text_mode(a2mem_if.TEXT_MODE);
                page2_r                 <= video_control_if.page2(a2mem_if.PAGE2);
                hires_mode_r            <= video_control_if.hires_mode(a2mem_if.HIRES_MODE);
                mixed_mode_r            <= video_control_if.mixed_mode(a2mem_if.MIXED_MODE);
                col80_r                 <= video_control_if.col80(a2mem_if.COL80);
                store80_r               <= video_control_if.store80(a2mem_if.STORE80);
                an3_r                   <= video_control_if.an3(a2mem_if.AN3);
                altchar_r               <= video_control_if.altchar(a2mem_if.ALTCHAR);

                text_color_r            <= video_control_if.text_color(a2mem_if.TEXT_COLOR);
                background_color_r      <= video_control_if.background_color(a2mem_if.BACKGROUND_COLOR);
                monochrome_mode_r       <= video_control_if.monochrome_mode(a2mem_if.MONOCHROME_MODE);
                monochrome_dhires_mode_r <= video_control_if.monochrome_dhires_mode(a2mem_if.MONOCHROME_DHIRES_MODE);
                shrg_mode_r             <= video_control_if.shrg_mode(a2mem_if.SHRG_MODE);
            end

            case (state_r)

            // ================================================================
            ST_IDLE: begin
                if (pixel_stream.hsync && visible_w) begin
                    render_line_r <= pixel_stream.scanline[7:0];
                    line_base_r <= lineaddr({2'b0, pixel_stream.scanline[7:0]}, next_GR);

                    chunk_r <= 5'd0;
                    pix_cnt_r <= 5'd0;
                    fe_step_r <= 4'd0;
                    fe_done_r <= 1'b0;
                    primed_r <= 1'b0;
                    fe_chunk_r <= 5'd0;
                    h_offset_r <= 6'd0;
                    next_pix_delay_r <= 1'b0;
                    scanline_pix_cnt_r <= 10'd0;
                    hsync_tick_cnt_r <= 5'd0;

                    pix_shift_r <= '0;
                    pix_history_r <= '0;
                    pix_delay_r <= 1'b0;
                    pix_step4_r <= (next_line_type_w == HIRES80_LINE || next_line_type_w == LORES80_LINE) ? 2'd1 : 2'd0;
                    pix_step7_r <= 3'd0;
                    pix_color_r <= next_GR ? 4'h0 : background_color_r;

                    state_r <= ST_ACTIVE;
                end
            end

            // ================================================================
            ST_ACTIVE: begin

                // Count pixel_clk_en ticks since scanline start (for PIXEL_START_TICK)
                if (pixel_stream.pixel_clk_en && hsync_tick_cnt_r < 5'd31)
                    hsync_tick_cnt_r <= hsync_tick_cnt_r + 5'd1;

                // ============================================================
                // FETCH/EXPAND PIPELINE — runs every cycle when not done
                // ============================================================
                if (!fe_done_r) begin
                    case (fe_step_r)
                        // --- BRAM fetch (common to all modes) ---
                        4'd0: begin
                            video_address_o <= line_base_r + {9'd0, h_offset_r};
                            video_bank_o <= video_bank_r;
                            video_rd_o <= 1'b1;
                            fe_step_r <= 4'd1;
                        end
                        4'd1: begin
                            video_rd_o <= 1'b0;          // deassert rd after 1 cycle
                            fe_step_r <= 4'd2;
                        end
                        4'd2: begin
                            if (video_ready_i)           // wait for VRAM data ready
                                fe_step_r <= 4'd3;
                        end

                        4'd3: begin
                            video_data_r <= video_data_i;
                            case (line_type_w)
                                HIRES40_LINE: begin
                                    next_pix_buffer_r <= expandHires40(video_data_i);
                                    next_pix_delay_r <= video_data_i[7];
                                    fe_done_r <= 1'b1;
                                end
                                HIRES80_LINE: begin
                                    next_pix_buffer_r[27:0] <= expandHires80(video_data_i);
                                    next_pix_buffer_r[28] <= 1'b0;
                                    next_pix_delay_r <= 1'b0;
                                    fe_done_r <= 1'b1;
                                end
                                LORES40_LINE: begin
                                    next_pix_buffer_r[27:0] <= expandLores40(video_data_i, render_line_r[2]);
                                    next_pix_buffer_r[28] <= 1'b0;
                                    next_pix_delay_r <= 1'b0;
                                    fe_done_r <= 1'b1;
                                end
                                LORES80_LINE: begin
                                    next_pix_buffer_r[27:0] <= expandLores80(video_data_i, render_line_r[2]);
                                    next_pix_buffer_r[28] <= 1'b0;
                                    next_pix_delay_r <= 1'b0;
                                    fe_done_r <= 1'b1;
                                end
                                default: begin
                                    fe_step_r <= 4'd4;
                                end
                            endcase
                        end

                        // --- TEXT40/TEXT80: character ROM lookups ---
                        4'd4: begin
                            case (line_type_w)
                                TEXT40_LINE: begin
                                    viderom_a_r <= charRomAddr(video_data_r[7:0], render_line_r[2:0]);
                                    fe_step_r <= 4'd5;
                                end
                                TEXT80_LINE: begin
                                    viderom_a_r <= charRomAddr(video_data_r[7:0], render_line_r[2:0]);
                                    fe_step_r <= 4'd5;
                                end
                                default: fe_done_r <= 1'b1;
                            endcase
                        end

                        4'd5: begin
                            case (line_type_w)
                                TEXT40_LINE: begin
                                    viderom_a_r <= charRomAddr(video_data_r[23:16], render_line_r[2:0]);
                                    fe_step_r <= 4'd6;
                                end
                                TEXT80_LINE: begin
                                    viderom_a_r <= charRomAddr(video_data_r[15:8], render_line_r[2:0]);
                                    fe_step_r <= 4'd6;
                                end
                                default: fe_done_r <= 1'b1;
                            endcase
                        end

                        4'd6: begin
                            case (line_type_w)
                                TEXT40_LINE: begin
                                    next_pix_buffer_r[13:0] <= expandText40(viderom_d_r);
                                    next_pix_buffer_r[28] <= 1'b0;
                                    next_pix_delay_r <= 1'b0;
                                    fe_step_r <= 4'd7;
                                end
                                TEXT80_LINE: begin
                                    next_pix_buffer_r[13:7] <= viderom_d_r[6:0];
                                    next_pix_buffer_r[28] <= 1'b0;
                                    next_pix_delay_r <= 1'b0;
                                    viderom_a_r <= charRomAddr(video_data_r[23:16], render_line_r[2:0]);
                                    fe_step_r <= 4'd7;
                                end
                                default: fe_done_r <= 1'b1;
                            endcase
                        end

                        4'd7: begin
                            case (line_type_w)
                                TEXT40_LINE: begin
                                    next_pix_buffer_r[27:14] <= expandText40(viderom_d_r);
                                    fe_done_r <= 1'b1;
                                end
                                TEXT80_LINE: begin
                                    next_pix_buffer_r[6:0] <= viderom_d_r[6:0];
                                    viderom_a_r <= charRomAddr(video_data_r[31:24], render_line_r[2:0]);
                                    fe_step_r <= 4'd8;
                                end
                                default: fe_done_r <= 1'b1;
                            endcase
                        end

                        4'd8: begin
                            next_pix_buffer_r[27:21] <= viderom_d_r[6:0];
                            fe_step_r <= 4'd9;
                        end

                        4'd9: begin
                            next_pix_buffer_r[20:14] <= viderom_d_r[6:0];
                            fe_done_r <= 1'b1;
                        end

                        default: fe_done_r <= 1'b1;
                    endcase
                end

                // ============================================================
                // PRIMING: load first chunk before starting pixel output
                // ============================================================
                if (!primed_r) begin
                    if (fe_done_r) begin
                        pix_shift_r <= next_pix_buffer_r;
                        pix_delay_r <= next_pix_delay_r;
                        primed_r <= 1'b1;

                        fe_chunk_r <= 5'd1;
                        h_offset_r <= 6'd2;
                        fe_step_r <= 4'd0;
                        fe_done_r <= 1'b0;
                    end
                end

                // ============================================================
                // PIXEL OUTPUT — active when primed, gated by pixel_clk_en
                // Delayed by PIXEL_START_TICK to ensure deterministic phase
                // with vdp_cx for SuperSprite overlay alignment
                // ============================================================
                else if (pixel_stream.pixel_clk_en && pixel_start_ok_w) begin

                    // Shift history with current pixel
                    pix_history_r <= {pix_shift_r[0], pix_history_r[PIX_HISTORY_SIZE-1:1]};

                    // Color computation
                    if (BW) begin
                        pix_color_r <= pix_history_r[HISTORY_PIXEL_OFFSET] ? 4'hF : 4'h0;
                    end else if (!GR) begin
                        // text mode
                        if (pix_history_r[HISTORY_PIXEL_OFFSET])
                            pix_color_r <= text_color_r;
                        else
                            pix_color_r <= background_color_r;
                    end else begin
                        // graphics mode
                        pix_color_r <= (FORCE_NIBBLE_COLORS | sw_gs_i) & lores_line_type_w
                            ? nibble_pre_r : rot_artifact_pre_r;
                    end

                    // Output active when past warmup and within 560 pixels
                    if (scanline_pix_cnt_r >= WARMUP_PIXELS && scanline_pix_cnt_r < (WARMUP_PIXELS + 10'd560))
                        pixel_active_r <= 1'b1;
                    else
                        pixel_active_r <= 1'b0;

                    scanline_pix_cnt_r <= scanline_pix_cnt_r + 10'd1;

                    pix_nibble_r <= nibble_pre_r;

                    // Shift pixel data
                    pix_shift_r <= {1'b0, pix_shift_r[PIX_BUFFER_SIZE-1:1]};

                    // Advance step counters
                    pix_step4_r <= pix_step4_r + 2'd1;
                    pix_step7_r <= (pix_step7_r == 3'd6) ? 3'd0 : pix_step7_r + 3'd1;

                    // Advance pixel counter within chunk
                    pix_cnt_r <= pix_cnt_r + 5'd1;

                    if (pix_cnt_r == STEP_LENGTH - 1) begin
                        pix_cnt_r <= 5'd0;
                        chunk_r <= chunk_r + 5'd1;

                        // Load next chunk into shift register
                        if (chunk_r + 5'd1 < NUM_CHUNKS) begin
                            pix_shift_r <= {next_pix_buffer_r[PIX_BUFFER_SIZE-1:1],
                                            next_pix_delay_r ? pix_shift_r[0] : next_pix_buffer_r[0]};
                            pix_delay_r <= next_pix_delay_r;

                            // Start fetching next chunk
                            if (fe_chunk_r < NUM_CHUNKS) begin
                                fe_chunk_r <= fe_chunk_r + 5'd1;
                                h_offset_r <= h_offset_r + 6'd2;
                                fe_step_r <= 4'd0;
                                fe_done_r <= 1'b0;
                            end
                        end
                    end

                    // Scanline complete
                    if (scanline_pix_cnt_r == (WARMUP_PIXELS + 10'd560)) begin
                        pixel_active_r <= 1'b0;
                        state_r <= ST_IDLE;
                    end
                end

            end // ST_ACTIVE

            default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
