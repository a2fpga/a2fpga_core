//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Part Number: GW5AT-LV60PG484AC1/I0
//Device: GW5AT-60
//Device Version: B


//Change the instance name and port connections to the signal names
//--------Copy here to design--------
    pll_ddr3 your_instance_name(
        .clkin(clkin), //input  clkin
        .clkout0(clkout0), //output  clkout0
        .clkout2(clkout2), //output  clkout2
        .lock(lock), //output  lock
        .mdopc(mdopc), //input [1:0] mdopc
        .mdainc(mdainc), //input  mdainc
        .mdwdi(mdwdi), //input [7:0] mdwdi
        .mdrdo(mdrdo), //output [7:0] mdrdo
        .pll_init_bypass(pll_init_bypass), //input  pll_init_bypass
        .mdclk(mdclk), //input  mdclk
        .reset(reset) //input  reset
);


//--------Copy end-------------------
