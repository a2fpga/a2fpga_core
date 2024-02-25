`timescale 1ns / 1ps
//
// Apple II Video Controller
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
// Implements the Apple II video controller, including the video ROM and the
// video scanner.  Supports all Apple II video modes, including text, lores,
// and hires graphics modes.  The video scanner is optimized for modern SDRAM
// memory access and is designed to be efficient and non-blocking to allow
// concurrent access to the SDRAM by other modules in the design.
//

module apple_video (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,

    video_control_if.display video_control_if,

    input wire [9:0] screen_x_i,
    input wire [9:0] screen_y_i,

    output reg [15:0] video_address_o,
    output reg video_bank_o,
    output reg video_rd_o,
    input [31:0] video_data_i,

    output wire video_active_o,
    output [7:0] video_r_o,
    output [7:0] video_g_o,
    output [7:0] video_b_o
);

    localparam FORCE_NIBBLE_COLORS = 1;
    localparam FORCE_MONOCHROME = 0;
    localparam FORCE_GS_PALETTE = 0;

    localparam STEP_LENGTH = 28;

    localparam PIX_BUFFER_SIZE = STEP_LENGTH + 1; // 29
    localparam PIX_HISTORY_SIZE = 8;

    localparam SCAN_PIX_OFFSET = STEP_LENGTH + PIX_HISTORY_SIZE - 4;

    localparam HISTORY_ARTIFACT_OFFSET = 1;
    localparam HISTORY_PIXEL_OFFSET = 4;

    localparam [9:0] WINDOW_WIDTH = 560;
    localparam [9:0] WINDOW_HEIGHT = 384;
    localparam [9:0] SCREEN_WIDTH = 720;
    localparam [9:0] SCREEN_HEIGHT = 480;
    localparam [9:0] FRAME_WIDTH = 858;
    localparam [9:0] FRAME_HEIGHT = 525;
    localparam [9:0] H_BORDER = (SCREEN_WIDTH - WINDOW_WIDTH) / 2;
    localparam [9:0] V_BORDER = (SCREEN_HEIGHT - WINDOW_HEIGHT) / 2;
    localparam [9:0] H_LEFT_BORDER = H_BORDER - 1;
    localparam [9:0] H_RIGHT_BORDER = H_BORDER + WINDOW_WIDTH;
    localparam [9:0] V_TOP_BORDER = V_BORDER - 1;
    localparam [9:0] V_BOTTOM_BORDER = V_BORDER + WINDOW_HEIGHT;

    wire x_active_w = (screen_x_i > H_LEFT_BORDER) & (screen_x_i < H_RIGHT_BORDER);
    wire scan_x_active_w = (screen_x_i > (H_LEFT_BORDER - SCAN_PIX_OFFSET)) & (screen_x_i < (H_RIGHT_BORDER - SCAN_PIX_OFFSET));
    wire y_active_w = (screen_y_i > V_TOP_BORDER) & (screen_y_i < V_BOTTOM_BORDER);
    assign video_active_o = x_active_w & y_active_w;
    wire scan_active_w = scan_x_active_w & y_active_w;
    wire generate_active_w = scan_active_w | video_active_o;
    wire blanking_active_w = (screen_x_i > SCREEN_WIDTH) | (screen_y_i > SCREEN_HEIGHT);
    wire scan_start_w = (screen_x_i == (H_LEFT_BORDER - SCAN_PIX_OFFSET)) & y_active_w;

    wire [9:0] window_x_w = x_active_w ? screen_x_i - H_BORDER : SCREEN_WIDTH;
    wire [9:0] window_y_w = y_active_w ? ((screen_y_i - V_BORDER) >> 1) : WINDOW_HEIGHT;

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
    reg [3:0] border_color_r;
    reg monochrome_mode_r;
    reg monochrome_dhires_mode_r;
    reg shrg_mode_r;

    // Only latch video mode registers when blanking is active to avoid screen tearing

    always @(posedge a2bus_if.clk_pixel) begin
        if (blanking_active_w) begin
            video_bank_r                 <= video_control_if.enable;
            text_mode_r                 <= video_control_if.text_mode(a2mem_if.TEXT_MODE);
            page2_r                     <= video_control_if.page2(a2mem_if.PAGE2);
            hires_mode_r                <= video_control_if.hires_mode(a2mem_if.HIRES_MODE);
            mixed_mode_r                <= video_control_if.mixed_mode(a2mem_if.MIXED_MODE);
            col80_r                     <= video_control_if.col80(a2mem_if.COL80);
            store80_r                   <= video_control_if.store80(a2mem_if.STORE80);
            an3_r                       <= video_control_if.an3(a2mem_if.AN3);
            altchar_r                   <= video_control_if.altchar(a2mem_if.ALTCHAR);

            text_color_r                <= video_control_if.text_color(a2mem_if.TEXT_COLOR);
            background_color_r          <= video_control_if.background_color(a2mem_if.BACKGROUND_COLOR);
            border_color_r              <= video_control_if.border_color(a2mem_if.BORDER_COLOR);
            monochrome_mode_r           <= video_control_if.monochrome_mode(a2mem_if.MONOCHROME_MODE);
            monochrome_dhires_mode_r    <= video_control_if.monochrome_dhires_mode(a2mem_if.MONOCHROME_DHIRES_MODE);
            shrg_mode_r                 <= video_control_if.shrg_mode(a2mem_if.SHRG_MODE);
        end
    end

    wire GR = ~(text_mode_r | (window_y_w[5] & window_y_w[7] & mixed_mode_r));

    // ----------------------------------------------------------------------------------------------------------------
    //
    // Video ROM
    //
    // This is a 4Kx8 ROM that contains the 8x8 character bitmaps for the Apple //e.  The ROM is loaded from a file
    // that has been converted into hex format.  Other ROM dumps can be used but should map the format.  We're only
    // using the text entries in the ROM, not the hi-res or lores graphics entries.
    //

    reg [7:0] viderom_r[4095:0];
    initial $readmemh("video.hex", viderom_r, 0);
    reg [11:0] viderom_a_r;
    reg [7:0] viderom_d_r;
    always @(posedge a2bus_if.clk_pixel) viderom_d_r <= ~viderom_r[viderom_a_r];

    reg [22:0] flash_cnt_r;
    always @(posedge a2bus_if.clk_pixel) flash_cnt_r <= flash_cnt_r + 1'b1;
    wire flash_clk_w = flash_cnt_r[22];

    // ----------------------------------------------------------------------------------------------------------------
    //
    // Utility functions
    //
    // These functions are used to expand the 32-bit video data into the 28-bit pixel data based on the current video
    // mode and Apple II video memory layout. This is an optimized version of the video logic as documented in the
    // Apple II Reference Manual and the Apple IIgs Hardware Reference Manual as well as Understanding the Apple IIe
    // by Jim Sather.
    //

    // Regular Hires
    function automatic bit [28:0] expandHires40([31:0] vd);
        reg [28:0] vs;
        case ({vd[23],vd[7]})
            2'b00: vs = {   // undelayed, undelayed
                            1'b0,
                            vd[22],vd[22],vd[21],vd[21],
                            vd[20],vd[20],vd[19],vd[19],
                            vd[18],vd[18],vd[17],vd[17],
                            vd[16],vd[16],vd[6],vd[6], 
                            vd[5],vd[5],vd[4],vd[4],
                            vd[3],vd[3],vd[2],vd[2],
                            vd[1],vd[1],vd[0],vd[0]
            };
            2'b01: vs = {   // undelayed, delayed
                            1'b0,
                            vd[22],vd[22],vd[21],vd[21],
                            vd[20],vd[20],vd[19],vd[19],
                            vd[18],vd[18],vd[17],vd[17],
                            vd[16],vd[16],vd[6],vd[5],
                            vd[5],vd[4],vd[4],vd[3],
                            vd[3],vd[2],vd[2],vd[1],
                            vd[1],vd[0],vd[0],1'b0
            };
            2'b10: vs = {   // delayed, undelayed
                            vd[22],
                            vd[22],vd[21],vd[21],vd[20],
                            vd[20],vd[19],vd[19],vd[18],
                            vd[18],vd[17],vd[17],vd[16],
                            vd[16],vd[16] & vd[6] /* 1'b0 */,vd[6],vd[6],  // workaround for artifact glitch, should not be necessary
                            vd[5],vd[5],vd[4],vd[4],
                            vd[3],vd[3],vd[2],vd[2],
                            vd[1],vd[1],vd[0],vd[0]
            };
            2'b11: vs = {   // delayed, delayed
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

    // Regular Lores
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
                vd[19],vd[18],vd[17],vd[16],
                vd[19],vd[18],vd[17],vd[24],
                vd[27],vd[26],vd[25],vd[24],
                vd[27],vd[26],vd[1],vd[0],
                vd[3],vd[2],vd[1],vd[0],
                vd[3],vd[10],vd[9],vd[8],
                vd[11],vd[10],vd[9],vd[8]
            };
            1'b1: vs = { 
                vd[23],vd[22],vd[21],vd[20],
                vd[23],vd[22],vd[21],vd[28],
                vd[31],vd[30],vd[29],vd[28],
                vd[31],vd[30],vd[5],vd[4],
                vd[7],vd[6],vd[5],vd[4],
                vd[7],vd[14],vd[13],vd[12],
                vd[15],vd[14],vd[13],vd[12]
            };
        endcase
        return vs;
    endfunction

    // Memory address generation, per Sather
    function automatic bit [15:0] lineaddr([9:0] y);
        reg [15:0] a;
        a[2:0] = 4'b0;
        a[6:3] = ({ 1'b1, y[6], 1'b1, 1'b1}) + 
                 ({ y[7], 1'b1, y[7], 1'b1}) + 
                 ({ 3'b000,           y[6]});
        a[9:7] = y[5:3];
        a[14:10] = (hires_mode_r & GR) == 1'b0 ?
            {2'b00, 1'b0, page2_r &  ~store80_r, ~(page2_r &  ~store80_r)} : 
            {page2_r &  ~store80_r, ~(page2_r &  ~store80_r), y[2:0]};
        a[15] = 1'b0;
        return a;
    endfunction

    // ----------------------------------------------------------------------------------------------------------------
    //
    // Video Scanner
    //
    // This is a state machine that scans the video screen and generates the pixel data for the current pixel.  This is
    // loosely based on the Apple II video logic but is optimized for efficiency of memory access to 32-bit memory such
    // as modern SDRAM.  While the original Apple II fetched 8-bits at a time and 7 pixels per fetch, and the Apple //e
    // fetched 16-bits at a time and 14 pixels per fetch, this logic fetches 32-bits at a time and 28 pixels per fetch.
    // This results in much more efficient memory access and allows the SDRAM to be used concurrently by other modules
    // in the design that need access to the memory, such as sound generation and other co-processors.
    //
    // Scanning consists of generating the address for the memory controller, waiting a suitable amount of time for the
    // memory controller to fetch the data, and then processing the data to generate the pixel data for 28 pixels at a
    // time.  The pixel data is stored in a shift register and shifted out one bit per pixel clock.  The shift register
    // is 29 bits wide to allow for the 28 pixels plus one bit of delay for Apple II hires graphics mode.
    //

    localparam [2:0] TEXT40_LINE = 0;
    localparam [2:0] TEXT80_LINE = 1;
    localparam [2:0] LORES40_LINE = 4;
    localparam [2:0] LORES80_LINE = 5;
    localparam [2:0] HIRES40_LINE = 6;
    localparam [2:0] HIRES80_LINE = 7;

    localparam [4:0] STEP_FIRST = 0;
    localparam [4:0] STEP_LAST = STEP_LENGTH - 1;
    localparam [4:0] STEP_LOAD_MEM = STEP_FIRST;
    localparam [4:0] STEP_LATCH_MEM = 14;

    localparam [7:0] STAGE_LOAD_MEM = {STEP_FIRST, 3'b???};
    localparam [7:0] STAGE_LATCH_MEM = {STEP_LATCH_MEM, 3'b???};
    localparam [7:0] STAGE_TEXT_0 = {STEP_LATCH_MEM + 5'd1, 3'b0??};
    localparam [7:0] STAGE_TEXT40_1 = {STEP_LATCH_MEM + 5'd2, TEXT40_LINE};
    localparam [7:0] STAGE_TEXT40_2 = {STEP_LATCH_MEM + 5'd3, TEXT40_LINE};
    localparam [7:0] STAGE_TEXT40_3 = {STEP_LATCH_MEM + 5'd4, TEXT40_LINE};
    localparam [7:0] STAGE_TEXT80_1 = {STEP_LATCH_MEM + 5'd2, TEXT80_LINE};
    localparam [7:0] STAGE_TEXT80_2 = {STEP_LATCH_MEM + 5'd3, TEXT80_LINE};
    localparam [7:0] STAGE_TEXT80_3 = {STEP_LATCH_MEM + 5'd4, TEXT80_LINE};
    localparam [7:0] STAGE_TEXT80_4 = {STEP_LATCH_MEM + 5'd5, TEXT80_LINE};
    localparam [7:0] STAGE_TEXT80_5 = {STEP_LATCH_MEM + 5'd6, TEXT80_LINE};
    localparam [7:0] STAGE_LORES40 = {STEP_LATCH_MEM + 5'd1, LORES40_LINE};
    localparam [7:0] STAGE_LORES80 = {STEP_LATCH_MEM + 5'd1, LORES80_LINE};
    localparam [7:0] STAGE_HIRES40 = {STEP_LATCH_MEM + 5'd1, HIRES40_LINE};
    localparam [7:0] STAGE_HIRES80 = {STEP_LATCH_MEM + 5'd1, HIRES80_LINE};
    localparam [7:0] STAGE_LOAD_SHIFT = {STEP_LAST, 3'b???};

    wire [2:0] line_type_w = (!GR & !col80_r) ? TEXT40_LINE : 
        (!GR & col80_r) ? TEXT80_LINE : 
        (GR & !hires_mode_r & an3_r) ? LORES40_LINE : 
        (GR & col80_r & !hires_mode_r & !an3_r) ? LORES80_LINE : 
        (GR & !col80_r & hires_mode_r & an3_r) ? HIRES40_LINE : 
        (GR & col80_r & hires_mode_r & !an3_r) ? HIRES80_LINE : 
        TEXT40_LINE;

    wire lores_line_type_w = (line_type_w == LORES40_LINE) | (line_type_w == LORES80_LINE);

    reg [4:0] pix_step_r;
    reg [2:0] pix_step7_r;
    reg [1:0] pix_step4_r;
    always @(posedge a2bus_if.clk_pixel) begin
        if (scan_start_w) begin
            pix_step_r <= '0;
            // shifted by 1 to account for 1-bit delay in double hires/lores graphics mode
            pix_step4_r <= (line_type_w == HIRES80_LINE) | (line_type_w == LORES80_LINE) ? 2'b01 : 2'b00;
            //pix_step4_r <= 2'b00;
            pix_step7_r <= 3'd0;
        end else begin
            pix_step_r <= (pix_step_r == STEP_LAST) ? 5'b0 : pix_step_r + 5'b1;
            pix_step4_r <= pix_step4_r + 2'b1;
            pix_step7_r <= pix_step7_r == 3'd6 ? 3'd0 : pix_step7_r + 3'd1;
        end
    end

    reg [5:0] h_offset_r;
    reg [31:0] video_data_r;

    reg [PIX_BUFFER_SIZE-1:0] pix_buffer_r;
    reg [PIX_BUFFER_SIZE-1:0] pix_shift_r/* synthesis syn_srlstyle = "registers" */;
    reg pix_delay_r;
    wire pix_out_w = pix_shift_r[0];
    
    wire [7:0] pix_stage_w = {pix_step_r, line_type_w};

    always @(posedge a2bus_if.clk_pixel) begin

        pix_shift_r <= {1'b0, pix_shift_r[PIX_BUFFER_SIZE-1:1]};

        video_rd_o <= 1'b0;

        if (!scan_active_w) begin
            h_offset_r <= '0;
            //pix_buffer_r <= 29'b0;
            //pix_shift_r <= '0;
        end else begin

            case (pix_stage_w) inside
                // start read
                STAGE_LOAD_MEM: begin
                    video_address_o <= lineaddr(window_y_w) + h_offset_r;
                    video_bank_o <= video_bank_r;
                    video_rd_o <= 1'b1;
                end
                // latch data
                STAGE_LATCH_MEM: begin
                    video_data_r <= video_data_i;
                    pix_delay_r <= 1'b0;
                    pix_buffer_r[28] <= 1'b0;
                end
                // handle hires40
                STAGE_HIRES40: begin
                    pix_buffer_r[28:0] <= expandHires40(video_data_r);
                    pix_delay_r <= video_data_r[7];
                end
                // handle hires80
                STAGE_HIRES80: begin
                    pix_buffer_r[27:0] <= expandHires80(video_data_r);
                end
                // handle lores40
                STAGE_LORES40: begin
                    pix_buffer_r[27:0] <= expandLores40(video_data_r, window_y_w[2]);
                end
                // handle lores80
                STAGE_LORES80: begin
                    pix_buffer_r[27:0] <= expandLores80(video_data_r, window_y_w[2]);
                end
                // start text
                STAGE_TEXT_0: begin
                    viderom_a_r <= {
                        1'b0,
                        video_data_r[7] | (video_data_r[6] & flash_clk_w & ~altchar_r),
                        video_data_r[6] & (altchar_r | video_data_r[7]),
                        video_data_r[5:0], 
                        window_y_w[2:0]
                    };
                end
                // handle text40
                STAGE_TEXT40_1: begin
                    viderom_a_r <= {
                        1'b0,
                        video_data_r[23] | (video_data_r[22] & flash_clk_w & ~altchar_r),
                        video_data_r[22] & (altchar_r | video_data_r[23]),
                        video_data_r[21:16],
                        window_y_w[2:0]
                    };
                end
                STAGE_TEXT40_2: begin
                    pix_buffer_r[13:0] <= expandText40(viderom_d_r);
                end
                STAGE_TEXT40_3: begin
                    pix_buffer_r[27:14] <= expandText40(viderom_d_r);
                end
                // handle text80
                STAGE_TEXT80_1: begin
                    viderom_a_r <= {
                        1'b0,
                        video_data_r[15] | (video_data_r[14] & flash_clk_w & ~altchar_r),
                        video_data_r[14] & (altchar_r | video_data_r[15]),
                        video_data_r[13:8], 
                        window_y_w[2:0]
                    };
                end
                STAGE_TEXT80_2: begin
                    pix_buffer_r[13:7] <= viderom_d_r[6:0];
                    viderom_a_r <= {
                        1'b0,
                        video_data_r[23] | (video_data_r[22] & flash_clk_w & ~altchar_r),
                        video_data_r[22] & (altchar_r | video_data_r[23]),
                        video_data_r[21:16], 
                        window_y_w[2:0]
                    };
                end
                STAGE_TEXT80_3: begin
                    pix_buffer_r[6:0] <= viderom_d_r[6:0];
                    viderom_a_r <= {
                        1'b0,
                        video_data_r[31] | (video_data_r[30] & flash_clk_w & ~altchar_r),
                        video_data_r[30] & (altchar_r | video_data_r[31]),
                        video_data_r[29:24], 
                        window_y_w[2:0]
                    };
                end
                STAGE_TEXT80_4: begin
                    pix_buffer_r[27:21] <= viderom_d_r[6:0];
                end
                STAGE_TEXT80_5: begin
                    pix_buffer_r[20:14] <= viderom_d_r[6:0];
                end
                // prepare for next cycle
                STAGE_LOAD_SHIFT: begin
                    h_offset_r <= h_offset_r + 6'd2;
                    pix_shift_r <= {pix_buffer_r[PIX_BUFFER_SIZE-1:1], pix_delay_r ? pix_out_w : pix_buffer_r[0]};
                end 
            endcase
        end
        
    end

    // ----------------------------------------------------------------------------------------------------------------
    //
    // Color Generation
    //
    // This section generates the color for the current pixel based on the current video and a color scheme based
    // on rules encoded into the artifact lookup table that determines whether to use the current 4-bit nibble pixel
    // value or to do artifacting. A 7 pixel window is used to look up the color palette index for the current pixel.
    //

    wire GSP = FORCE_GS_PALETTE | a2bus_if.sw_gs;

    // Apple II color palette for sRGB, 4 bits per channel (0 to 15)
    // https://groups.google.com/g/comp.sys.apple2/c/uILy74pRsrk/m/G9XDxQhWi1AJ

    // IIgs palette from Apple IIgs Techical Note #63 Master Color Values
    // https://archive.org/details/IIgs_2523063_Master_Color_Values

    reg [11:0] palette_rgb_r[0:31] = '{
    // Apple II color palette for sRGB, 4 bits per channel (0 to 15)
        12'h000, // 0   Black (Hires 0 & 3)
        12'h924, // 1   Magenta
        12'h42a, // 2   Dark Blue
        12'hd4e, // 3   Purple (Hires 2)
        12'h064, // 4   Dark Green
        12'h888, // 5   Dark Gray
        12'h39e, // 6   Blue (Hires 6)
        12'hcbf, // 7   Light Blue
        12'h450, // 8   Brown
        12'hc73, // 9   Orange (Hires 5)
        12'h888, // 10  Light Gray
        12'hfac, // 11  Pink
        12'h3c2, // 12  Green (Hires 1)
        12'hcd6, // 13  Yellow
        12'h7ec, // 14  Aquamarine
        12'hfff, // 15  White (Hires 4 & 7)
    // Apple IIgs color palette (16 to 31)
        12'h000, // 0   Black
        12'hd03, // 1   Deep Red
        12'h009, // 2   Dark Blue
        12'hd2d, // 3   Purple
        12'h072, // 4   Dark Green
        12'h555, // 5   Dark Gray   
        12'h22f, // 6   Medium Blue
        12'h6af, // 7   Light Blue
        12'h850, // 8   Brown
        12'hf60, // 9   Orange
        12'haaa, // 10  Light Gray
        12'hf98, // 11  Pink
        12'h1d0, // 12  Light Green
        12'hff0, // 13  Yellow
        12'h4f9, // 14  Aquamarine
        12'hfff  // 15  White
    };

    // Apple II color artifact_r table from MAME, reduced to 4 bits
    // https://github.com/mamedev/mame/blob/master/src/mame/apple/apple2video.cpp#L225
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

    reg [PIX_HISTORY_SIZE-1:0] pix_history_r;

    // For lores40/lores80, skip the artifact_r lookup and use the current 4-bit pixel value

    wire pix_nibble_capture_w = lores_line_type_w ? pix_step7_r == 3'd0 : pix_step4_r == 2'd0;
    reg [3:0] pix_nibble_r;

    function automatic bit [3:0] getCurrentNibble();
        reg [3:0] n;
        if (lores_line_type_w & (pix_step7_r == 3'd4)) begin
            case (pix_step4_r)
                2'b00: n = pix_history_r[7:4];
                2'b01: n = {pix_history_r[6:4], pix_history_r[7]};
                2'b10: n = {pix_history_r[5:4], pix_history_r[7:6]};
                2'b11: n = {pix_history_r[4], pix_history_r[7:5]};
            endcase
        end else if (!lores_line_type_w & (pix_step4_r == 2'd0)) begin
            n = pix_history_r[7:4];
        end else begin
            n = pix_nibble_r;
        end
        return n;
    endfunction

    always @(posedge a2bus_if.clk_pixel) begin
        pix_nibble_r <= getCurrentNibble();
    end

    wire [3:0] pix_nibble_w = getCurrentNibble();

    // For hires40/hires80, use the artifact_r lookup table to determine the color palette index for the current pixel

    wire [6:0] artifact_window_w = pix_history_r[HISTORY_ARTIFACT_OFFSET + 6:HISTORY_ARTIFACT_OFFSET];
    wire [3:0] pix_artifact_w = artifact_r[artifact_window_w];
    wire [3:0] rot_pix_artifact_w = pix_step4_r == 2'b00 ? pix_artifact_w : 
        pix_step4_r == 2'b01 ? {pix_artifact_w[2], pix_artifact_w[1], pix_artifact_w[0], pix_artifact_w[3]} : 
        pix_step4_r == 2'b10 ? {pix_artifact_w[1], pix_artifact_w[0], pix_artifact_w[3], pix_artifact_w[2]} : 
        {pix_artifact_w[0], pix_artifact_w[3], pix_artifact_w[2], pix_artifact_w[1]};

    wire BW = FORCE_MONOCHROME | monochrome_mode_r | monochrome_dhires_mode_r;

    reg [3:0] pix_color_r;

    always @(posedge a2bus_if.clk_pixel) begin

        pix_history_r <= {pix_out_w, pix_history_r[PIX_HISTORY_SIZE-1:1]};

        pix_color_r <= background_color_r;
  
        if (video_active_o) begin
            if (BW) begin
                if (pix_history_r[HISTORY_PIXEL_OFFSET]) begin
                    pix_color_r <= 4'hF;
                end else begin
                    pix_color_r <= 4'h0;
                end
            end else if (!GR) begin 		// text mode 
                if (pix_history_r[HISTORY_PIXEL_OFFSET]) begin
                    pix_color_r <= text_color_r;
                end
            end else begin                  // graphics mode
                // IIgs uses emulated artifacts for hires40/hires80 and *no* artifacts for lores40/lores80
                pix_color_r <= (FORCE_NIBBLE_COLORS | a2bus_if.sw_gs) & lores_line_type_w ? pix_nibble_w : rot_pix_artifact_w;
            end
        end else begin
            pix_color_r <= border_color_r;
        end
        
    end

    wire [11:0] pix_rgb = palette_rgb_r[{GSP, pix_color_r}];
    wire [3:0] pix_b = pix_rgb[3:0];
    wire [3:0] pix_g = pix_rgb[7:4];
    wire [3:0] pix_r = pix_rgb[11:8];

    assign video_r_o = {pix_r, 4'h0};
    assign video_g_o = {pix_g, 4'h0};
    assign video_b_o = {pix_b, 4'h0};
    
endmodule
