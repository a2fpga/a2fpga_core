//Copyright (C)2014-2023 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.8.11 Education
//Created Time: 2023-06-02 16:47:45

create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}] -add

// Reference PLL output pins directly to avoid net renaming issues
create_generated_clock -name clk_logic -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 2 -add [get_pins {clk_logic_inst/rpll_inst/CLKOUT}]
create_generated_clock -name clk_pixel -source [get_pins {clk_logic_inst/rpll_inst/CLKOUT}] -master_clock clk_logic -divide_by 2 -multiply_by 1 -add [get_pins {clk_logic_inst/rpll_inst/CLKOUTD}]
create_generated_clock -name clk_hdmi -source [get_pins {clk_logic_inst/rpll_inst/CLKOUTD}] -master_clock clk_pixel -divide_by 1 -multiply_by 5 -add [get_pins {clk_hdmi_inst/rpll_inst/CLKOUT}]

// SPI clock from BL616 MCU (4 MHz, used as direct clock for SPI shift registers)
create_clock -name spi_sclk -period 250.000 [get_ports {spi_sclk}]

// CDC between SPI clock domain and system clock domain uses toggle synchronizer.
// These cross-domain paths are safe by design -- false path both directions.
set_false_path -from [get_clocks {spi_sclk}] -to [get_clocks {clk_logic}]
set_false_path -from [get_clocks {clk_logic}] -to [get_clocks {spi_sclk}]

