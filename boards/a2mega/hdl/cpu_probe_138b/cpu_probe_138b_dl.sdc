// S7 fast-core probe — DATA-LATE step (CPU_PROBE_DATALATE).  One clock per
// step, every path single-cycle: the period is the step time, Fmax the step
// rate.  0.5 ns setup uncertainty per the project timing policy.
// History (exploration log, 2026-11-11): at a 20.0 ns target the first roll
// reported 49.5 MHz (worst slack -0.19 ns, 38 paths); 21.0 ns = 47.6 MHz is
// the clean-close target.  The 2x-AppleSqueezer goal needs >= 33-36 MHz.
create_clock -name clk_cpu -period 21.000 -waveform {0 10.500} [get_ports {clk50_in}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk_cpu}]
