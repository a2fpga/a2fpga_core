//Copyright (C)2014-2023 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.8.11 Education
//Created Time: 2023-06-02 16:47:45

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

create_generated_clock -name clk_logic -source [get_ports {clk}] -master_clock clk -divide_by 50 -multiply_by 54 -add [get_nets {clk_logic_w}]
create_generated_clock -name clk_pixel -source [get_nets {clk_logic_w}] -master_clock clk_logic -divide_by 2 -multiply_by 1 -add [get_nets {clk_pixel_w}]
create_generated_clock -name clk_hdmi -source [get_nets {clk_pixel_w}] -master_clock clk_pixel -divide_by 1 -multiply_by 5 -add [get_nets {clk_hdmi_w}]
