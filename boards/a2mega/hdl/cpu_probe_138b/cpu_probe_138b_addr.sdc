// S7 fast-core probe — ADDRESS-CONE measurement variant.
// Clock = the real 108 MHz; the whole 3-clock step is given to every path by
// default, and only the paths from core registers into the BSRAM address
// pins are held to one clock.  The report's worst paths are then the
// address cone (regs -> ADDR_BUS -> BSRAM address setup), which the normal
// probe never shows because the data cone is longer.
create_clock -name clk_cpu -period 27.780 -waveform {0 13.890} [get_ports {clk50_in}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk_cpu}]
set_max_delay 9.260 -from [get_regs {u_cpu/*}] -to [get_pins {mem_mem*/AD*}]
