//
// Apple IIgs Video Graphics Controller
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
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
// This module is responsible for generating the Apple IIgs Super Hires Graphics output.
// Unlike the actual IIgs VGC, this module does not generate the regular Apple II
// video output. Instead, it generates the Super Hires Graphics output and mixes it
// with the regular Apple II video output.
//
// This typically uses block RAM to store the Super Hires Graphics data, but it can
// also use regular RAM assuming the memory controller can fetch each new 32-bit word
// within 12 cycles of the pixel clock (or 24 cycles of the logic clock) from the time
// that the vgc_rd_o signal is asserted.
//

module vgc (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,

    video_control_if.display video_control_if,

    input [9:0] cx_i,
    input [9:0] cy_i,

    input [7:0] apple_vga_r_i,
    input [7:0] apple_vga_g_i,
    input [7:0] apple_vga_b_i,

    output [7:0] vgc_vga_r_o,
    output [7:0] vgc_vga_g_o,
    output [7:0] vgc_vga_b_o,

    output reg [7:0] R_o,
    output reg [7:0] G_o,
    output reg [7:0] B_o,

    output vgc_active_o,
    output [12:0] vgc_address_o,
    output vgc_rd_o,
    input [31:0] vgc_data_i

);

    // 320x200, 640x200 modes
    // 0-39 top border
    // 40-439 display
    // 440-479 bottom border

    // load 32 bits each cycle
    // 40 display cycles
    // 1 scan line control cycle
    // 8 palette cycles
    // 1 unused cycle

    localparam [9:0] WINDOW_WIDTH = 640;
    localparam [9:0] WINDOW_HEIGHT = 400;
    localparam [9:0] SCREEN_WIDTH = 720;
    localparam [9:0] SCREEN_HEIGHT = 480;
    localparam [9:0] FRAME_WIDTH = 858;
    localparam [9:0] FRAME_HEIGHT = 525;
    localparam [9:0] H_BORDER = (SCREEN_WIDTH - WINDOW_WIDTH) / 2;      // 40
    localparam [9:0] V_BORDER = (SCREEN_HEIGHT - WINDOW_HEIGHT) / 2;    // 40
    localparam [9:0] H_LEFT_BORDER = H_BORDER - 1;                      // 39
    localparam [9:0] H_RIGHT_BORDER = H_BORDER + WINDOW_WIDTH;          // 680
    localparam [9:0] V_TOP_BORDER = V_BORDER - 1;                       // 39
    localparam [9:0] V_BOTTOM_BORDER = V_BORDER + WINDOW_HEIGHT;        // 440
    localparam [9:0] H_FIRST = H_BORDER;                                // 40
    localparam [9:0] H_LAST = H_RIGHT_BORDER - 1;                       // 679
    localparam [9:0] V_FIRST = V_BORDER;                                // 40
    localparam [9:0] V_LAST = V_BOTTOM_BORDER - 1;                      // 439
    localparam [9:0] H_WRAP = FRAME_WIDTH - H_BORDER;                   // 818
    localparam [5:0] LAST_CYCLE = (FRAME_WIDTH / 16) - 1;               // 52

    wire [ 9:0] pix_x_w = cx_i < H_FIRST ? H_WRAP + cx_i : cx_i - H_BORDER;

    reg  [12:0] scanline_addr_r;

    always @(posedge a2bus_if.clk_pixel) begin
        if (cx_i == H_LAST) begin
            if (cy_i == V_TOP_BORDER) begin
                scanline_addr_r <= '0;
            end else if (cy_i[0]) begin
                scanline_addr_r <= scanline_addr_r + 13'd40;
            end
        end
    end

    wire [5:0] cycle_w = pix_x_w[9:4];                                  // increments at pixel clock div 8
    wire [3:0] cycle_step_w = pix_x_w[3:0];                             // increments at pixel clock
    wire fetch_mem_w = cycle_step_w == 4'd2;
    wire latch_mem_w = cycle_step_w == 4'd15;

    wire addr_inc_w = (cycle_w < LAST_CYCLE) & (cycle_step_w == 4'b0001);

    wire pointer_fetch_w = cycle_w == 6'd39;
    wire pointer_load_w = cycle_w == 6'd40;
    wire palette_load_w = (cycle_w > 6'd40) && (cycle_w < 6'd49);
    wire pixel_fetch_w = cycle_w == LAST_CYCLE;

    // we retrieve 2 palette entries per cycle
    // need to store them one at a time
    wire store_palette_even_w = cycle_step_w == 4'd0;
    wire store_palette_odd_w = cycle_step_w == 4'd1;

    wire display_active_w = (cycle_w < 6'd40) && ((cy_i > V_TOP_BORDER) && (cy_i < V_BOTTOM_BORDER));

    // set up interface to memory

    reg [12:0] vram_addr_r;
    reg [31:0] vram_data_r;

    assign vgc_active_o = a2mem_if.SHRG_MODE;
    assign vgc_address_o = vram_addr_r;
    assign vgc_rd_o = fetch_mem_w;

    // derive scanline number from HDMI vertical counter

    wire [7:0] scanline_w = 8'((cy_i - V_TOP_BORDER) >> 1);

    wire [7:0] control_data_w = scanline_w[1:0] == 3 ? vram_data_r[31:24] :
        scanline_w[1:0] == 2 ? vram_data_r[23:16] :
        scanline_w[1:0] == 1 ? vram_data_r[15:8] :
        vram_data_r[7:0];
    reg [7:0] scan_ctl_r;
    wire PIX640 = scan_ctl_r[7];
    wire COLOR_FILL_MODE = scan_ctl_r[5];

    reg [11:0] palette_rgb_r[15:0];

    wire [3:0] palette_load_i = {cycle_w[2:0] - 1'b1, 1'b0};

    wire [7:0] pix_byte_w = pix_x_w[3:2] == 2'd3 ? vram_data_r[31:24] :
        pix_x_w[3:2] == 2'd2 ? vram_data_r[23:16] :
        pix_x_w[3:2] == 2'd1 ? vram_data_r[15:8] :
        vram_data_r[7:0];

    wire [3:0] pix320_w = pix_x_w[1] ? pix_byte_w[3:0] : pix_byte_w[7:4];

    wire [1:0] pix640_w = pix_x_w[1:0] == 2'd3 ? pix_byte_w[1:0] :
        pix_x_w[1:0] == 2'd2 ? pix_byte_w[3:2] :
        pix_x_w[1:0] == 2'd1 ? pix_byte_w[5:4] :
        pix_byte_w[7:6];

    wire [1:0] pix640_palette_select_w = pix_x_w[1:0] == 2'd3 ? 2'b01 :
        pix_x_w[1:0] == 2'd2 ? 2'b00 :
        pix_x_w[1:0] == 2'd1 ? 2'b11 :
        2'b10;

    reg [3:0] prev_pix_palette_r;
    wire [3:0] pix_palette_w = PIX640 ? {pix640_palette_select_w, pix640_w} : pix320_w;
    wire [3:0] pix_fill_w = COLOR_FILL_MODE && (pix_palette_w == 4'b0000) ? prev_pix_palette_r : pix_palette_w;
    wire [11:0] pix_rgb_w = palette_rgb_r[pix_fill_w];
    wire [3:0] pix_b_w = pix_rgb_w[3:0];
    wire [3:0] pix_g_w = pix_rgb_w[7:4];
    wire [3:0] pix_r_w = pix_rgb_w[11:8];

    always @(posedge a2bus_if.clk_pixel) begin

        if (latch_mem_w) vram_data_r <= vgc_data_i;

        if (addr_inc_w) vram_addr_r <= vram_addr_r + 1'b1;

        if (pointer_fetch_w) begin
            vram_addr_r <= 13'd8000 + scanline_w[7:2];                  // set up address for pointer fetch
        end else if (pointer_load_w) begin
            scan_ctl_r <= control_data_w;                               // capture scan line control data
            vram_addr_r <= 13'd8064 + {control_data_w[3:0], 3'b000};    // set up address for palette fetch
        end else if (palette_load_w) begin
            if (store_palette_even_w) begin
                palette_rgb_r[palette_load_i] <= vram_data_r[11:0];
            end else if (store_palette_odd_w) begin
                palette_rgb_r[palette_load_i+1] <= vram_data_r[27:16];
            end
        end else if (pixel_fetch_w) begin
            vram_addr_r <= scanline_addr_r;
        end

    end

    always @(posedge a2bus_if.clk_pixel) begin
        R_o <= 0;
        G_o <= 0;
        B_o <= 0;
        if (display_active_w) begin
            R_o <= {pix_r_w, 4'h0};
            G_o <= {pix_g_w, 4'h0};
            B_o <= {pix_b_w, 4'h0};
            prev_pix_palette_r <= pix_fill_w;
        end else begin
            prev_pix_palette_r <= 4'b0000;
        end
    end

    wire VGC_OUTPUT = a2mem_if.SHRG_MODE & display_active_w & !video_control_if.enable;
    assign vgc_vga_r_o = VGC_OUTPUT ? R_o : apple_vga_r_i;
    assign vgc_vga_g_o = VGC_OUTPUT ? G_o : apple_vga_g_i;
    assign vgc_vga_b_o = VGC_OUTPUT ? B_o : apple_vga_b_i;

endmodule
