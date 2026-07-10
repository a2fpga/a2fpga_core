//Copyright (C)2014-2023 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file (DUAL_RATE_SDRAM build)
//GOWIN Version: 1.9.8.11 Education
//Created Time: 2023-06-02 16:47:45

create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}] -add

// PLL: 27 MHz x 4 = 108 MHz SDRAM clock
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 4 -add [get_pins {clk_logic_inst/rpll_inst/CLKOUT}]

// CLKDIV2: 108 MHz / 2 = 54 MHz logic clock
create_generated_clock -name clk_logic -source [get_pins {clk_logic_inst/rpll_inst/CLKOUT}] -master_clock clk_sdram -divide_by 2 -multiply_by 1 -add [get_pins {clkdiv2_inst/CLKOUT}]

// PLL CLKOUTD: 108 MHz / 4 = 27 MHz pixel clock
create_generated_clock -name clk_pixel -source [get_pins {clk_logic_inst/rpll_inst/CLKOUT}] -master_clock clk_sdram -divide_by 4 -multiply_by 1 -add [get_pins {clk_logic_inst/rpll_inst/CLKOUTD}]

// HDMI PLL: 27 MHz x 5 = 135 MHz
create_generated_clock -name clk_hdmi -source [get_pins {clk_logic_inst/rpll_inst/CLKOUTD}] -master_clock clk_pixel -divide_by 1 -multiply_by 5 -add [get_pins {clk_hdmi_inst/rpll_inst/CLKOUT}]

// SPI clock from BL616 MCU (4 MHz, used as direct clock for SPI shift registers)
create_clock -name spi_sclk -period 250.000 [get_ports {spi_sclk}]

// CDC between SPI clock domain and system clock domain uses toggle synchronizer.
// These cross-domain paths are safe by design -- false path both directions.
set_false_path -from [get_clocks {spi_sclk}] -to [get_clocks {clk_logic}]
set_false_path -from [get_clocks {clk_logic}] -to [get_clocks {spi_sclk}]

// clk_sdram (108 MHz) and clk_logic (54 MHz) are synchronous via CLKDIV2.
// Binary pointer CDC relies on CLKDIV2 alignment guarantee.
// NOTE: set_multicycle_path is broken on Gowin (relaxes ALL domain paths).
// NOTE: set_max_delay squeezes Fmax to 0.3% margin, destabilizing SDRAM.
// false_path is the only viable SDC constraint; CDC robustness must come
// from the HDL design (gray-code FIFO) rather than from routing constraints.
// (Same rationale as the a2n20v2-GS board.)
set_false_path -from [get_clocks {clk_logic}] -to [get_clocks {clk_sdram}]
set_false_path -from [get_clocks {clk_sdram}] -to [get_clocks {clk_logic}]

// CDC false paths -- audio CDC and direct_display raster/pixel CDC. With
// CLKDIV2 in the tree, clk_logic and clk_pixel no longer share a
// PLL-guaranteed phase relationship; crossings must be (and are) handled
// in HDL (cdc registers in the direct_display path, staged audio CDC).
set_false_path -from [get_clocks {clk_logic}] -to [get_clocks {clk_pixel}]
set_false_path -from [get_clocks {clk_pixel}] -to [get_clocks {clk_logic}]
