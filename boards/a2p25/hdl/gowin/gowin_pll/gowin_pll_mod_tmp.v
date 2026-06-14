//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.11.03
//Part Number: GW5A-LV25MG121NC1/I0
//Device: GW5A-25
//Device Version: B
//Created Time: Sat Jul 19 11:37:58 2025

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    Gowin_PLL_MOD your_instance_name(
        .lock(lock), //output lock
        .clkout0(clkout0), //output clkout0
        .clkout1(clkout1), //output clkout1
        .clkout2(clkout2), //output clkout2
        .mdrdo(mdrdo), //output [7:0] mdrdo
        .clkin(clkin), //input clkin
        .reset(reset), //input reset
        .mdclk(mdclk), //input mdclk
        .mdopc(mdopc), //input [1:0] mdopc
        .mdainc(mdainc), //input mdainc
        .mdwdi(mdwdi) //input [7:0] mdwdi
    );

//--------Copy end-------------------
