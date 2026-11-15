// WHAT-IF measurement, not a contract: the STEP_CLKS = 2 probe with every path
// given one whole 20 ns step (as if the broker's decisions were step-rate
// registers on a real step clock).  Shows what the core <-> memory loop costs
// inside the integrated design when nothing else is in the way.
create_clock -name clk100 -period 20.000 -waveform {0 10.000} [get_ports {clk50_in}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk100}]
create_clock -name gs_ph2 -period 349.0 -waveform {209.4 349.0} [get_ports {gs_ph2}]
set_clock_groups -asynchronous -group [get_clocks {gs_ph2}] -group [get_clocks {clk100}]
set_false_path -from [get_regs {cfg_*}]
set_false_path -from [get_regs {ld_a_* ld_d_* ld_we_*}]
