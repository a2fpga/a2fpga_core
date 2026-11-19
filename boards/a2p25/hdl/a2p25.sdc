// a2p25 displayport1 full core — clocks. Logic/HyperRAM from the i_hr_pll
// cascade (clk_hr = clk_logic), DP from i_mgmt_pll / the D-PHY PLL / the pixel PLL.
// Apple II bus clocks are sampled (cdc) and left unconstrained, as on the a2mega.
// a2p25 DP bring-up timing constraints — 4-lane RBR 1080p60 variant

// 50 MHz SOM oscillator
create_clock -name clk50  -period 20.000 -waveform {0 10.000} [get_ports {clk}]

// 100 MHz AUX/management clock (gowin_mgmt_pll)
create_clock -name clk100 -period 10.000 -waveform {0 5.000} [get_pins {i_mgmt_pll/PLLA_inst/CLKOUT0}]

// 54 MHz D-PHY PLL reference (board PLL, VCO 1350 / 25)
create_clock -name clk54  -period 18.519 -waveform {0 9.259} [get_pins {i_sys_pll/u_pll/PLLA_inst/CLKOUT2}]

// D-PHY PLL: VCO 810 MHz. clkout4 / 10 = 81 MHz link-symbol clock.
create_clock -name clk_sym -period 12.346 -waveform {0 6.173} [get_pins {i_phy/u_dphy/u_pll/PLLA_inst/CLKOUT4}]

// 101.25 MHz D-PHY byte clock (16-bit gearbox), from the hard PHY
create_clock -name clk_tx -period 9.877 -waveform {0 4.938} [get_pins {i_phy/u_dphy/u_mipi_dphy/mipi_dphy_inst/TX_CLK_O}]

// 148.5 MHz pixel clock: 81 MHz * 11 / 6 (gowin_pixel_pll, VCO 891)
create_clock -name clk_pix -period 6.734 -waveform {0 3.367} [get_pins {i_dp/i_pixel_pll/PLLA_inst/CLKOUT0}]

// All domain crossings go through gray-coded FIFOs or 2FF synchronizers.

// HyperRAM clock cascade: clk54 (i_sys_pll) -> i_hr_pll: clk_hr (54, user side),
// clk_mem (108, HyperBus CK), clk_mem_90 (+90 deg, drives CK). Same as
// a2p25_psram_test_ck108.sdc but on this project's instance names.
create_clock -name clk_hr     -period 18.519 -waveform {0 9.259} [get_pins {i_hr_pll/PLLA_inst/CLKOUT0}]
create_clock -name clk_mem    -period 9.259 -waveform {0 4.630} [get_pins {i_hr_pll/PLLA_inst/CLKOUT1}]
create_clock -name clk_mem_90 -period 9.259 -waveform {2.315 6.944} [get_pins {i_hr_pll/PLLA_inst/CLKOUT2}]
set_false_path -from [get_regs {i_hr_ctrl/dly_code*}]
// Reset release into the controller's clk_mem re-registration (rst_n_m):
// hr_rst_sync_r[2] toggles exactly once per power/reset event and is stable
// for thousands of cycles either side, and the controller sits in reset
// until it propagates — the single-cycle 54->108 requirement on this cone
// is not real (it failed -0.148 ns on a placement roll, 8.9 ns of route).
// Scoped to this crossing only; clk_hr-domain release paths stay timed.
set_false_path -from [get_regs {hr_rst_sync_r_2*}] -to [get_regs {i_hr_ctrl/rst_n_m*}]
# Audio output filter (hdl/support/iir_filter_gw5a.v under i_audio_out): every
# register inside IIR_filter is enabled by the filter ce (or the 48 kHz sample
# ce), and audio_out's accumulator fires that ce at most every fifth clk54
# (54 MHz / 11.19 MHz), so a tap update -- the input product, the 40-bit add,
# the tap product (MULT12X12 pieces and their adder trees) -- may take three
# cycles. Register-to-register inside the
# filter only; the inputs (cl/cr in audio_out) and the outputs stay single-cycle.
# Two things learned on the first builds (2026-11-18): a `*` in get_regs /
# get_pins did not cross a hierarchy level here (SUG940 says it can), so the
# taps' intreg one level down (iir_tap_N/intreg) get their own `*/*` patterns;
# and synthesis folds the ce-enabled `inp` register into the input multipliers'
# DSP pipeline registers (the q_* cells), so those paths launch from the DSP
# cells' DOUT pins, not from a fabric register (single-cycle the 27x36 version
# was -0.05 .. +0.02 ns; covered, a DSP -> DSP -> intreg path arrived at 26 ns
# against 57 ns).
# No bare -to pattern: it would also relax the single-cycle flt_ce -> CE paths.
set_multicycle_path 3 -setup -from [get_regs {i_audio_out/IIR_filter/*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 2 -hold  -from [get_regs {i_audio_out/IIR_filter/*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 3 -setup -from [get_regs {i_audio_out/IIR_filter/*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 2 -hold  -from [get_regs {i_audio_out/IIR_filter/*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 3 -setup -from [get_regs {i_audio_out/IIR_filter/*/*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 2 -hold  -from [get_regs {i_audio_out/IIR_filter/*/*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 3 -setup -from [get_regs {i_audio_out/IIR_filter/*/*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 2 -hold  -from [get_regs {i_audio_out/IIR_filter/*/*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 3 -setup -from [get_pins {i_audio_out/IIR_filter/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 2 -hold  -from [get_pins {i_audio_out/IIR_filter/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 3 -setup -from [get_pins {i_audio_out/IIR_filter/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 2 -hold  -from [get_pins {i_audio_out/IIR_filter/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 3 -setup -from [get_pins {i_audio_out/IIR_filter/*/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 2 -hold  -from [get_pins {i_audio_out/IIR_filter/*/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*}]
set_multicycle_path 3 -setup -from [get_pins {i_audio_out/IIR_filter/*/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_multicycle_path 2 -hold  -from [get_pins {i_audio_out/IIR_filter/*/*/DOUT*}] -to [get_regs {i_audio_out/IIR_filter/*/*}]
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {clk100}] -group [get_clocks {clk54}] -group [get_clocks {clk_sym}] -group [get_clocks {clk_tx}] -group [get_clocks {clk_pix}] -group [get_clocks {clk_hr clk_mem clk_mem_90}]
