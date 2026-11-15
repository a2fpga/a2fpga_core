// S7 fast-core probe — DATA-CONE measurement with the step structure modelled.
// In the real two-edge step only two classes of path are short:
//   regs -> BSRAM address   : one 108 MHz clock   (measured by the _addr variant)
//   BSRAM DO -> core regs    : two clocks = 18.52 ns (this variant's base period)
// Core-register -> core-register paths (microcode lookup, NextState, AddrGen
// adders -> regs) span the whole step; in the probe the core steps every
// other clock, so they are 2-cycle paths here.  The earlier probes held them
// to one clock too, which both hid the true data cone behind artefacts and
// spent placer effort on paths that have slack in the real design.
create_clock -name clk_cpu -period 18.520 -waveform {0 9.260} [get_ports {clk50_in}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk_cpu}]
set_multicycle_path 2 -setup -from [get_regs {u_cpu/*}] -to [get_regs {u_cpu/*}]
set_multicycle_path 1 -hold  -from [get_regs {u_cpu/*}] -to [get_regs {u_cpu/*}]
