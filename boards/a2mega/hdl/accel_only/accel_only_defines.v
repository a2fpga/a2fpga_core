// The accelerator-only build (a2mega_accel_138B.gprj, hdl/accel_only/accel_only_top.sv):
// listed first in the project.
// The core's microcode successor rows from block RAM (the two-clk step: F65C816.sv, rung 5)
`define F65C816_MCODE_ROM
// The accelerator's clock: 110 MHz (the S6 socket PLL) unless one of these is defined: then
// 105 MHz, or 100 MHz, which goes before it (gowin_acc_pll).  gen_sdc.py reads these lines
// for the board build's clock period.
`define ACC_CLK_105
//`define ACC_CLK_100
