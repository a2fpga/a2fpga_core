// A2N20v2-Enhanced dual-rate build wrapper.
//
// Compiles top.sv with DUAL_RATE_SDRAM defined: SDRAM controller at 108 MHz
// (GS-style split clock) with mem_port_cdc on every port. Used by
// a2n20v2_enhanced_dualrate.gprj together with a2n20v2_enhanced_dualrate.sdc
// (which false-paths clk_logic <-> clk_sdram / clk_pixel like the GS board).
// The default a2n20v2_enhanced.gprj compiles top.sv directly (single 54 MHz
// domain) and must NOT include this file.

`define DUAL_RATE_SDRAM
`include "top.sv"
