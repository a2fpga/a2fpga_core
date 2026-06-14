//Copyright (C)2014-2023 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.8.11 Education
//Created Time: 2023-06-02 16:47:45

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

// Reference PLL output pins directly to avoid net renaming issues
// clk_logic (54 MHz) comes from PLLA CLKOUT2
// clk_hdmi (135 MHz) comes from PLLA CLKOUT1
// clk_pixel (27 MHz) comes from CLKDIV dividing clk_hdmi by 5
create_generated_clock -name clk_logic -source [get_ports {clk}] -master_clock clk -divide_by 25 -multiply_by 27 -add [get_pins {clocks_pll/u_pll/PLLA_inst/CLKOUT2}]
create_generated_clock -name clk_hdmi -source [get_ports {clk}] -master_clock clk -divide_by 10 -multiply_by 27 -add [get_pins {clocks_pll/u_pll/PLLA_inst/CLKOUT1}]
create_generated_clock -name clk_pixel -source [get_pins {clocks_pll/u_pll/PLLA_inst/CLKOUT1}] -master_clock clk_hdmi -divide_by 5 -multiply_by 1 -add [get_pins {clkdiv_inst/CLKOUT}]

