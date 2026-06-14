//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12.01
//IP Version: 1.0
//Part Number: GW5AT-LV60PG484AC1/I0
//Device: GW5AT-60
//Device Version: B
//Created Time: Sat Feb  7 09:34:28 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    pll_hdmi_MOD your_instance_name(
        .lock(lock), //output lock
        .clkout0(clkout0), //output clkout0
        .clkout1(clkout1), //output clkout1
        .mdrdo(mdrdo), //output [7:0] mdrdo
        .clkin(clkin), //input clkin
        .reset(reset), //input reset
        .mdclk(mdclk), //input mdclk
        .mdopc(mdopc), //input [1:0] mdopc
        .mdainc(mdainc), //input mdainc
        .mdwdi(mdwdi) //input [7:0] mdwdi
    );

//--------Copy end-------------------
