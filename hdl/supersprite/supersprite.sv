//
// SuperSprite clone for the Apple II
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
// The SuperSprite card provides a TI TMS9918A VDP, an AY-3-8910 PSG
// sound generator, and the TMS5220 voice synthesizer.  The card also
// provides a video overlay feature that allows the VDP to overlay
// the Apple II's video output.  The original card is designed to be used in
// slot 7.
//
// This implementation is a clone of the original card, using the F18A
// implementation of the TMS9918A VDP.  Speech synthesis is not yet
// implemented.
//
// This implementation has been tested with all original Synetix
// SuperSprite software, including the SuperSprite demo disk.
//
// Of note is the overlay mechanism which uses black-level detection
// rather than the 9918a's external video mode.  In the course of this
// implementation, it was discovered that the SuperSprite card does not
// use the 9918a's external video mode, but instead uses a black-level
// detection mechanism to switch between the 9918a's video output and
// the Apple's video output.  This implemenation supports that behavior
// by default, but also supports the 9918a's external video mode when
// the 9918a's register 0 bit 7 external video switch is set to 1.
//

module SuperSprite #(
    parameter [7:0] ID = 1,
    parameter bit ENABLE = 1'b1,
    parameter bit FORCE_VDP_OVERLAY = 1'b0
) (
    a2bus_if.slave a2bus_if,
    slot_if.card slot_if,

    output [7:0] data_o,
    output rd_en_o,
    output irq_n_o,

    input wire [9:0] screen_x_i,
    input wire [9:0] screen_y_i,

    input [7:0] apple_vga_r_i,
    input [7:0] apple_vga_g_i,
    input [7:0] apple_vga_b_i,
    input apple_vga_active_i,
    input scanlines_i,

    output [7:0] ssp_r_o,
    output [7:0] ssp_g_o,
    output [7:0] ssp_b_o,

    output scanlines_o,
    output vdp_ext_video_o,
    output vdp_unlocked_o,
    output [3:0] vdp_gmode_o,

    f18a_gpu_if.master f18a_gpu_if,

    output [15:0] ssp_audio_o

);

    wire card_sel = ENABLE && (slot_if.card_id == ID);
    wire card_dev_sel = card_sel && !slot_if.devselect_n;
    wire card_io_sel = card_sel && !slot_if.ioselect_n;

    localparam [3:0] VDP_VRAM_ADDRESS = 4'h0;
    localparam [3:0] VDP_REGISTER_ADDRESS = 4'h1;
    localparam [3:0] VDP_RESET_ADDRESS = 4'h7;

    localparam [3:0] SPEECH_ADDRESS = 4'h2;

    localparam [3:0] VIDEO_SWITCH_APPLE_OFF = 4'h3;
    localparam [3:0] VIDEO_SWITCH_APPLE_ON = 4'h4;
    localparam [3:0] VIDEO_SWITCH_APPLE_OUT = 4'h5;
    localparam [3:0] VIDEO_SWITCH_MIX_OUT = 4'h6;

    localparam [3:0] SOUND_DATA_WRITE = 4'hC;
    localparam [3:0] SOUND_DATA_READ_REG_WRITE = 4'hE;

    wire ADDR_VDP = a2bus_if.addr[3:1] == 3'b0;
    wire ADDR_PSG = a2bus_if.addr[3:2] == SOUND_DATA_WRITE[3:2];

    reg  vdp_overlay_sw;
    reg  apple_video_sw;

    // capture the soft switches
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            vdp_overlay_sw <= FORCE_VDP_OVERLAY;
            apple_video_sw <= 1'b1;
        end else if (ENABLE && (slot_if.card_id == ID) && (a2bus_if.phi1_posedge) && !slot_if.devselect_n) begin
            case (a2bus_if.addr[3:0])
                VIDEO_SWITCH_APPLE_OFF: apple_video_sw <= 1'b0;
                VIDEO_SWITCH_APPLE_ON:  apple_video_sw <= 1'b1;
                VIDEO_SWITCH_APPLE_OUT: vdp_overlay_sw <= FORCE_VDP_OVERLAY;
                VIDEO_SWITCH_MIX_OUT:   vdp_overlay_sw <= 1'b1;
            endcase
        end
    end

    // VDP Select when address is in range for SuperSprite or EZ-Color
    wire vdp_rd = card_dev_sel && ADDR_VDP && a2bus_if.rw_n;
    wire vdp_wr = card_dev_sel && ADDR_VDP && !a2bus_if.rw_n;

    // SuperSprite PSG Select when address is in range for SuperSprite
    wire ssp_psg_data_rd = card_dev_sel && ADDR_PSG && a2bus_if.rw_n && a2bus_if.addr[1];
    wire ssp_psg_data_wr = card_dev_sel && ADDR_PSG && !a2bus_if.rw_n && !a2bus_if.addr[1];
    wire ssp_psg_address_wr = card_dev_sel && ADDR_PSG && !a2bus_if.rw_n && a2bus_if.addr[1];

    wire vdp_csw;
    reg [3:0] vdp_csw_delay = 4'b0;
    always @(posedge a2bus_if.clk_logic) vdp_csw_delay <= {vdp_csw_delay[2:0], vdp_wr};
    assign vdp_csw = (vdp_csw_delay[3:1] == 3'b110) | (vdp_csw_delay[3:1] == 3'b100);

    wire [0:7] vdp_d_o;

    wire vdp_irq_n_o;
    assign irq_n_o = vdp_irq_n_o || !ENABLE;

    wire [3:0] vdp_r;
    wire [3:0] vdp_g;
    wire [3:0] vdp_b;
    wire vdp_transparent;
    wire vdp_ext_video;

    f18a vdp (
        .clk_logic_i(a2bus_if.clk_logic),
        .clk_pixel_i(a2bus_if.clk_pixel),
        .reset_n_i(a2bus_if.device_reset_n),
        .mode_i(a2bus_if.addr[0]),
        .csw_n_i(!vdp_csw),
        .csr_n_i(!vdp_rd),
        .int_n_o(vdp_irq_n_o),
        .cd_i(a2bus_if.data),
        .cd_o(vdp_d_o),
        .raster_x_i(screen_x_i),
        .raster_y_i(screen_y_i),
        .blank_o(),
        .hsync_o(),
        .vsync_o(),
        .red_o(vdp_r),
        .grn_o(vdp_g),
        .blu_o(vdp_b),
        .transparent_o(vdp_transparent),
        .ext_video_o(vdp_ext_video),
        .sprite_max_i(1'b1),
        .scanlines_i(scanlines_i),
        .scanlines_o(scanlines_o),
        .unlocked_o(vdp_unlocked_o),
        .gmode_o(vdp_gmode_o),
        .gpu_if(f18a_gpu_if)
    );

    // PSG for SuperSprite

    wire [7:0] ssp_psg_d_o;
    wire [7:0] ssp_psg_ch_a_o, ssp_psg_ch_b_o, ssp_psg_ch_c_o;
    wire [13:0] ssp_psg_mix_audio_o, ssp_psg_pcm14s_o;

    YM2149 ssp_psg (
        .CLK(a2bus_if.clk_logic),
        .CE(a2bus_if.phi1_negedge & ENABLE),
        .RESET(!a2bus_if.system_reset_n),
        .BDIR(ssp_psg_address_wr || ssp_psg_data_wr),
        .BC(ssp_psg_data_rd || ssp_psg_address_wr),
        .DI(a2bus_if.data),
        .DO(ssp_psg_d_o),
        .CHANNEL_A(ssp_psg_ch_a_o),
        .CHANNEL_B(ssp_psg_ch_b_o),
        .CHANNEL_C(ssp_psg_ch_c_o),

        .SEL (1'b0),
        .MODE(1'b0),

        .ACTIVE(),

        .IOA_in (8'b0),
        .IOA_out(),

        .IOB_in (8'b0),
        .IOB_out()
    );

    assign ssp_audio_o = (
        ({4'b00, ssp_psg_ch_a_o, 4'b00}) + 
        ({4'b00, ssp_psg_ch_b_o, 4'b00}) + 
        ({4'b00, ssp_psg_ch_c_o, 4'b00}));

    assign data_o = ssp_psg_data_rd ? ssp_psg_d_o : vdp_d_o;
    assign rd_en_o = ssp_psg_data_rd || vdp_rd;

    wire [7:0] video_in_r =  /* apple_vga_active_i && */ apple_video_sw ? apple_vga_r_i : 8'b0;
    wire [7:0] video_in_g =  /* apple_vga_active_i && */ apple_video_sw ? apple_vga_g_i : 8'b0;
    wire [7:0] video_in_b =  /* apple_vga_active_i && */ apple_video_sw ? apple_vga_b_i : 8'b0;

    // The SuperSprite does not use the 9918a's external video mode, it does video mixing off-chip
    // by switching between the 9918a's video output and the Apple's video output based on the black
    // level of the 9918a.  This means that there is no way to have a black area produced by the VDP
    // that obscures the Apple video.  We would like to support the proper 9918a transparency behavior
    // so we enable this mode when the 9918a register 0 bit 7 external video switch is set to 1. 

    wire vdp_black = (vdp_r == 4'b0) && (vdp_g == 4'b0) && (vdp_b == 4'b0);

    // use the vdp pixel when either the vdp is in ext video mode and not transparent or in ssp overlay mode and not black
    wire vdp_pixel_en = ENABLE && vdp_overlay_sw && ((vdp_ext_video && !vdp_transparent) || (!vdp_ext_video && !vdp_black));

    assign ssp_r_o = vdp_pixel_en ? {vdp_r, 4'b0} : video_in_r;
    assign ssp_g_o = vdp_pixel_en ? {vdp_g, 4'b0} : video_in_g;
    assign ssp_b_o = vdp_pixel_en ? {vdp_b, 4'b0} : video_in_b;

    assign vdp_ext_video_o = vdp_ext_video;

endmodule
