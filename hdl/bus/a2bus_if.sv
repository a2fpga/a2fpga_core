//
// Apple II Bus Interface
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// SystemVerilog interface for the Apple II bus
//

interface a2bus_if (
);

    logic clk_logic;
    logic clk_pixel;
    logic system_reset_n;
    logic device_reset_n;

    logic phi0;
    logic phi0_posedge;
    logic phi0_negedge;

    logic phi1;
    logic phi1_posedge;
    logic phi1_negedge;

    logic clk_q3;
    logic clk_q3_posedge;
    logic clk_q3_negedge;

    logic clk_7M;
    logic clk_7M_posedge;
    logic clk_7M_negedge;

    logic clk_14M_posedge;

    logic rw_n;
    logic [15:0] addr;
    logic m2sel_n;
    logic m2b0;
    logic [7:0] data;
    logic data_in_strobe;
    logic sw_gs;
    logic extended_cycle;

    logic control_inh_n;
    logic control_irq_n;
    logic control_rdy_n;
    logic control_dma_n;
    logic control_nmi_n;
    logic control_reset_n;
    
    modport master (
        output clk_logic,
        output clk_pixel,
        output system_reset_n,
        output device_reset_n,

        output phi0,
        output phi0_posedge,
        output phi0_negedge,

        output phi1,
        output phi1_posedge,
        output phi1_negedge,

        output clk_q3,
        output clk_q3_posedge,
        output clk_q3_negedge,

        output clk_7M,
        output clk_7M_posedge,
        output clk_7M_negedge,

        output clk_14M_posedge,
        
        output rw_n,
        output addr,
        output m2sel_n,
        output m2b0,
        output data,
        output data_in_strobe,
        output sw_gs,
        output extended_cycle,

        output control_inh_n,
        output control_irq_n,
        output control_rdy_n,
        output control_dma_n,
        output control_nmi_n,
        output control_reset_n
    );

    modport slave (
        input clk_logic,
        input clk_pixel,
        input system_reset_n,
        input device_reset_n,

        input phi0,
        input phi0_posedge,
        input phi0_negedge,

        input phi1,
        input phi1_posedge,
        input phi1_negedge,

        input clk_q3,
        input clk_q3_posedge,
        input clk_q3_negedge,

        input clk_7M,
        input clk_7M_posedge,
        input clk_7M_negedge,

        input clk_14M_posedge,
        
        input rw_n,
        input addr,
        input m2sel_n,
        input m2b0,
        input data,
        input data_in_strobe,
        input sw_gs,
        input extended_cycle,

        input control_inh_n,
        input control_irq_n,
        input control_rdy_n,
        input control_dma_n,
        input control_nmi_n,
        input control_reset_n,

        import io_select_n,
        import dev_select_n,
        import io_strobe_n
    );

endinterface: a2bus_if

    