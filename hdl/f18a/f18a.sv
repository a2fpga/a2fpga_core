//
// SystemVerilog wrapper for the F18A implementation of the TMS9918A VDP
//
// Description:
//
// This module wraps the Matthew Hagerty F18A implementation of the TMS9918A VDP to
// provide a SystemVerilog interface to the VDP.  The purpose of this is to
// abstract out the GPU interface so that alternate co-processors can be
// used with the F18A VDP.
//
// See the accompanying f18a_gpu_if.sv for the interface definition.
//


module f18a (
    input wire clk_logic_i,
    input wire clk_pixel_i,

    // 9918A to Host System Interface
    input wire reset_n_i,  // Must be active for at least one 25MHz clock cycle
    input wire mode_i,
    input wire csw_n_i,
    input wire csr_n_i,
    output wire int_n_o,
    input wire [7:0] cd_i,
    output wire [7:0] cd_o,

    input wire [9:0] raster_x_i,
    input wire [9:0] raster_y_i,

    // Video Output
    output wire blank_o,
    output wire hsync_o,
    output wire vsync_o,
    output wire [3:0] red_o,
    output wire [3:0] grn_o,
    output wire [3:0] blu_o,
    output wire transparent_o,
    output wire ext_video_o,
    output wire scanlines_o,

    // Feature Selection
    input wire sprite_max_i,   // Default sprite max, '0' = 32, '1' = 4
    input wire scanlines_i,   // Simulated scan lines, '0' = no, '1' = yes
    output wire unlocked_o,
    output wire [3:0] gmode_o,

    f18a_gpu_if.master gpu_if
);

    f18a_core f18a_core (
        .clk_logic_i(clk_logic_i),
        .clk_pixel_i(clk_pixel_i),
        .reset_n_i(reset_n_i),
        .mode_i(mode_i),
        .csw_n_i(csw_n_i),
        .csr_n_i(csr_n_i),
        .int_n_o(int_n_o),
        .cd_i(cd_i),
        .cd_o(cd_o),
        .raster_x_i(raster_x_i),
        .raster_y_i(raster_y_i),
        .blank_o(blank_o),
        .hsync_o(hsync_o),
        .vsync_o(vsync_o),
        .red_o(red_o),
        .grn_o(grn_o),
        .blu_o(blu_o),
        .transparent_o(transparent_o),
        .ext_video_o(ext_video_o),
        .sprite_max_i(sprite_max_i),
        .scanlines_i(scanlines_i),
        .scanlines_o(scanlines_o),
        .unlocked_o(unlocked_o),
        .gmode_o(gmode_o),
        
        .gpu_trigger_o(gpu_if.trigger),
        .gpu_running_i(gpu_if.running),
        .gpu_pause_o(gpu_if.pause),
        .gpu_pause_ack_i(gpu_if.pause_ack),
        .gpu_load_pc_o(gpu_if.load_pc),
        .gpu_vdin_o(gpu_if.vdin),
        .gpu_vwe_i(gpu_if.vwe),
        .gpu_vaddr_i(gpu_if.vaddr),
        .gpu_vdout_i(gpu_if.vdout),
        .gpu_pdin_o(gpu_if.pdin),
        .gpu_pwe_i(gpu_if.pwe),
        .gpu_paddr_i(gpu_if.paddr),
        .gpu_pdout_i(gpu_if.pdout),
        .gpu_rdin_o(gpu_if.rdin),
        .gpu_raddr_i(gpu_if.raddr),
        .gpu_rwe_i(gpu_if.rwe),
        .gpu_scanline_o(gpu_if.scanline),
        .gpu_blank_o(gpu_if.blank),
        .gpu_bmlba_o(gpu_if.bmlba),
        .gpu_bml_w_o(gpu_if.bml_w),
        .gpu_pgba_o(gpu_if.pgba),
        .gpu_gstatus_i(gpu_if.gstatus)
    );

endmodule

