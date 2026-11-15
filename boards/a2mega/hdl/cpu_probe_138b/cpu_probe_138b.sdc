// S7 fast-core Fmax probe.  One clock; the core steps every other clock
// (address clock, then data clock), so the clock Fmax reported for clk_cpu
// is the frequency at which the BSRAM-out -> ALU -> flags cone closes, and
// equally the regs -> A_OUT -> BSRAM-address cone.  The period here is a
// target that pushes the placer (boards/a2mega/docs/timing_round2.md: the
// placer finds margin when the constraint asks); read the achieved Fmax from
// the report, not pass/fail.  The oscillator is 50 MHz; the probe is never
// flashed, so the physical rate is irrelevant.
create_clock -name clk_cpu -period 17.000 -waveform {0 8.500} [get_ports {clk50_in}]   // N = 3 budget: 2 x 9.26 ns data clocks minus the 0.5 ns policy, rounded down
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk_cpu}]
