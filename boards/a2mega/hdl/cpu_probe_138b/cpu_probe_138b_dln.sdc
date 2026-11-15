// S7 fast-core probe - DATA-LATE step with a 16 KB memory (CPU_PROBE_DATALATE +
// CPU_PROBE_NEAR_MEM): what the core does with a near memory the size of a
// cache instead of the whole 128 KB.  One clock per step, every path
// single-cycle: the period is the step time.  0.5 ns setup uncertainty per the
// project timing policy.
create_clock -name clk_cpu -period 19.000 -waveform {0 9.500} [get_ports {clk50_in}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk_cpu}]
