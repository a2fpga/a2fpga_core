// A2N20v2-Enhanced framebuffer build wrapper.
//
// Compiles top.sv with DUAL_RATE_SDRAM + VIDEO_FRAMEBUFFER defined: the GS
// board's beam-accurate video architecture (scan_timer-paced generators
// writing into an SDRAM framebuffer read out at HDMI rate) on the full
// Enhanced peripheral set. Used by a2n20v2_enhanced_fb.gprj, whose file
// list also selects the f18a `_fb` VHDL variants (external raster) instead
// of the stock free-running ones, together with a2n20v2_enhanced_dualrate.sdc.
// The default a2n20v2_enhanced.gprj compiles top.sv directly and must NOT
// include this file.

`define DUAL_RATE_SDRAM
`define VIDEO_FRAMEBUFFER
`include "top.sv"
