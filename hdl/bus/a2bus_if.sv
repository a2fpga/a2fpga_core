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
    input logic clk_logic,
    input logic clk_pixel,
    input logic system_reset_n,
    input logic device_reset_n,
    input logic phi0,
    input logic phi1,
    input logic phi1_posedge,
    input logic phi1_negedge,
    input logic clk_2m_posedge,
    input logic clk_7m,
    input logic clk_7m_posedge,
    input logic clk_7m_negedge,
    input logic clk_14m_posedge
);

    logic sw_gs;
    logic rw_n;
    logic [15:0] addr;
    logic m2sel_n;
    logic m2b0;
    logic [7:0] data;
    logic data_in_strobe;

    function automatic logic io_select_n (bit enable, int slot, bit int_cx_rom);
        bit [15:0] IO_ADDRESS = 16'hC000 + (slot << 8);
        return ~(enable & phi0 & (addr[15:8] == IO_ADDRESS[15:8]) & !m2sel_n) | int_cx_rom;
    endfunction

    function automatic logic dev_select_n (bit enable, int slot);
        bit [15:0] DEVICE_ADDRESS = 16'hC080 + (slot << 4);
        return ~(enable & phi0 & (addr[15:4] == DEVICE_ADDRESS[15:4]) & !m2sel_n);
    endfunction

    function automatic logic io_strobe_n (bit enable, bit int_cx_rom);
        return ~(enable & phi0 & (addr[15:11] == 5'b11001) & !m2sel_n) | int_cx_rom; // C800-CFFF
    endfunction

    modport master (
        input clk_logic,
        input clk_pixel,
        input system_reset_n,
        input device_reset_n,
        input phi0,
        input phi1,
        input phi1_posedge,
        input phi1_negedge,
        input clk_2m_posedge,
        input clk_7m,
        input clk_7m_posedge,
        input clk_7m_negedge,
        input clk_14m_posedge,
        
        output rw_n,
        output addr,
        output m2sel_n,
        output m2b0,
        output data,
        output data_in_strobe,
        output sw_gs
    );

    modport slave (
        input clk_logic,
        input clk_pixel,
        input system_reset_n,
        input device_reset_n,
        input phi0,
        input phi1,
        input phi1_posedge,
        input phi1_negedge,
        input clk_2m_posedge,
        input clk_7m,
        input clk_7m_posedge,
        input clk_7m_negedge,
        input clk_14m_posedge,
        
        input rw_n,
        input addr,
        input m2sel_n,
        input m2b0,
        input data,
        input data_in_strobe,
        input sw_gs,

        import io_select_n,
        import dev_select_n,
        import io_strobe_n
    );

endinterface: a2bus_if

    