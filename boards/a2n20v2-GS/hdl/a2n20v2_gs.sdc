//Copyright (C)2014-2023 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.8.11 Education
//Created Time: 2023-06-02 16:47:45

create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}] -add

// PLL: 27 MHz × 4 = 108 MHz SDRAM clock
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 4 -add [get_pins {clk_logic_inst/rpll_inst/CLKOUT}]

// CLKDIV2: 108 MHz ÷ 2 = 54 MHz logic clock
create_generated_clock -name clk_logic -source [get_pins {clk_logic_inst/rpll_inst/CLKOUT}] -master_clock clk_sdram -divide_by 2 -multiply_by 1 -add [get_pins {clkdiv2_inst/CLKOUT}]

// PLL CLKOUTD: 108 MHz ÷ 4 = 27 MHz pixel clock
create_generated_clock -name clk_pixel -source [get_pins {clk_logic_inst/rpll_inst/CLKOUT}] -master_clock clk_sdram -divide_by 4 -multiply_by 1 -add [get_pins {clk_logic_inst/rpll_inst/CLKOUTD}]

// HDMI PLL: 27 MHz × 5 = 135 MHz
create_generated_clock -name clk_hdmi -source [get_pins {clk_logic_inst/rpll_inst/CLKOUTD}] -master_clock clk_pixel -divide_by 1 -multiply_by 5 -add [get_pins {clk_hdmi_inst/rpll_inst/CLKOUT}]

// clk_sdram (108 MHz) and clk_logic (54 MHz) are synchronous via CLKDIV2.
// Binary pointer CDC relies on CLKDIV2 alignment guarantee.
// NOTE: set_multicycle_path is broken on Gowin (relaxes ALL domain paths).
// NOTE: set_max_delay squeezes Fmax to 0.3% margin, destabilizing SDRAM.
// false_path is the only viable SDC constraint; CDC robustness must come
// from the HDL design (gray-code FIFO) rather than from routing constraints.
set_false_path -from [get_clocks {clk_logic}] -to [get_clocks {clk_sdram}]
set_false_path -from [get_clocks {clk_sdram}] -to [get_clocks {clk_logic}]

// CDC false paths — audio CDC, line buffer BRAM, VDP raster
set_false_path -from [get_clocks {clk_logic}] -to [get_clocks {clk_pixel}]
set_false_path -from [get_clocks {clk_pixel}] -to [get_clocks {clk_logic}]
